#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>

#include "xdg-shell-client-protocol.h"

enum { WIDTH = 1280, HEIGHT = 720, MAX_INTERVALS = 4096 };

static struct wl_display *display;
static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct xdg_wm_base *wm_base;
static struct wl_surface *surface;
static struct xdg_surface *xdg_surface;
static struct wl_buffer *buffer;
static uint32_t *pixels;
static bool configured;
static bool running = true;

static int phase; /* 0 static, 1 damage */
static int static_ms = 3000;
static int damage_ms = 5000;
static int frame_count;
static int interval_count;
static int64_t phase_start_ns;
static int64_t first_frame_ns;
static int64_t last_frame_ns;
static int64_t intervals[MAX_INTERVALS];
static int tick;

static int64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static void paint(void) {
    uint32_t color = phase == 0 ? 0xff204060 : (uint32_t)(0xff000000 | ((tick * 16) & 255) << 16 | 0x4020);
    for (int i = 0; i < WIDTH * HEIGHT; i++)
        pixels[i] = color;
    int bar = (tick * 17) % WIDTH;
    for (int y = 0; y < HEIGHT; y++) {
        for (int x = bar; x < bar + 40 && x < WIDTH; x++)
            pixels[y * WIDTH + x] = 0xffffffff;
    }
}

static void xdg_wm_base_ping(void *data, struct xdg_wm_base *wm, uint32_t serial) {
    xdg_wm_base_pong(wm, serial);
}

static const struct xdg_wm_base_listener wm_base_listener = {.ping = xdg_wm_base_ping};

static void request_frame(void);

static void frame_done(void *data, struct wl_callback *cb, uint32_t time_ms) {
    (void)data;
    (void)time_ms;
    wl_callback_destroy(cb);
    int64_t now = now_ns();
    if (first_frame_ns < 0) {
        first_frame_ns = now;
        phase_start_ns = now;
    } else if (interval_count < MAX_INTERVALS) {
        intervals[interval_count++] = now - last_frame_ns;
    }
    last_frame_ns = now;
    frame_count++;

    int limit = phase == 0 ? static_ms : damage_ms;
    if ((now - phase_start_ns) / 1000000 >= limit) {
        running = false;
        return;
    }

    if (phase == 1) {
        tick++;
        paint();
        wl_surface_damage_buffer(surface, 0, 0, WIDTH, HEIGHT);
        wl_surface_attach(surface, buffer, 0, 0);
    }
    request_frame();
    wl_surface_commit(surface);
}

static const struct wl_callback_listener frame_listener = {.done = frame_done};

static void request_frame(void) {
    struct wl_callback *cb = wl_surface_frame(surface);
    wl_callback_add_listener(cb, &frame_listener, NULL);
}

static void xdg_surface_configure(void *data, struct xdg_surface *xdg, uint32_t serial) {
    xdg_surface_ack_configure(xdg, serial);
    if (!configured) {
        configured = true;
        paint();
        wl_surface_attach(surface, buffer, 0, 0);
        wl_surface_damage_buffer(surface, 0, 0, WIDTH, HEIGHT);
    }
    wl_surface_commit(surface);
}

static const struct xdg_surface_listener xdg_surface_listener = {.configure = xdg_surface_configure};

static void xdg_toplevel_configure(void *data, struct xdg_toplevel *toplevel, int32_t width, int32_t height, struct wl_array *states) {
    (void)data;
    (void)toplevel;
    (void)width;
    (void)height;
    (void)states;
}

static void xdg_toplevel_close(void *data, struct xdg_toplevel *toplevel) {
    (void)data;
    (void)toplevel;
    running = false;
}

static const struct xdg_toplevel_listener toplevel_listener = {
    .configure = xdg_toplevel_configure,
    .close = xdg_toplevel_close,
};

static void registry_global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
    (void)data;
    if (strcmp(interface, wl_compositor_interface.name) == 0)
        compositor = wl_registry_bind(registry, name, &wl_compositor_interface, 4);
    else if (strcmp(interface, wl_shm_interface.name) == 0)
        shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
    else if (strcmp(interface, xdg_wm_base_interface.name) == 0)
        wm_base = wl_registry_bind(registry, name, &xdg_wm_base_interface, 1);
}

static void registry_global_remove(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data;
    (void)registry;
    (void)name;
}

static const struct wl_registry_listener registry_listener = {
    .global = registry_global,
    .global_remove = registry_global_remove,
};

static struct wl_buffer *create_buffer(void) {
    size_t size = (size_t)WIDTH * HEIGHT * 4;
    int fd = memfd_create("frame-timer", MFD_CLOEXEC);
    if (fd < 0) {
        perror("memfd_create");
        exit(1);
    }
    if (ftruncate(fd, (off_t)size) < 0) {
        perror("ftruncate");
        exit(1);
    }
    pixels = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (pixels == MAP_FAILED) {
        perror("mmap");
        exit(1);
    }
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int32_t)size);
    struct wl_buffer *buf = wl_shm_pool_create_buffer(pool, 0, WIDTH, HEIGHT, WIDTH * 4, WL_SHM_FORMAT_ARGB8888);
    wl_shm_pool_destroy(pool);
    close(fd);
    return buf;
}

static void dump_phase(const char *name) {
    int64_t elapsed = 0;
    if (frame_count >= 1 && last_frame_ns >= first_frame_ns)
        elapsed = last_frame_ns - first_frame_ns;
    printf("%s_frames %d\n", name, frame_count);
    printf("%s_elapsed_ns %lld\n", name, (long long)elapsed);
    printf("%s_intervals_ns", name);
    for (int i = 0; i < interval_count; i++)
        printf(" %lld", (long long)intervals[i]);
    printf("\n");
    fflush(stdout);
}

static void reset_phase(void) {
    frame_count = 0;
    interval_count = 0;
    first_frame_ns = -1;
    last_frame_ns = -1;
    phase_start_ns = now_ns();
}

static void run_phase(void) {
    int limit = phase == 0 ? static_ms : damage_ms;
    reset_phase();
    running = true;
    tick++;
    paint();
    wl_surface_attach(surface, buffer, 0, 0);
    wl_surface_damage_buffer(surface, 0, 0, WIDTH, HEIGHT);
    request_frame();
    wl_surface_commit(surface);

    int fd = wl_display_get_fd(display);
    while (running && (now_ns() - phase_start_ns) / 1000000 < limit) {
        while (wl_display_prepare_read(display) != 0) {
            if (wl_display_dispatch_pending(display) == -1)
                return;
        }
        wl_display_flush(display);
        struct pollfd pfd = {.fd = fd, .events = POLLIN};
        int ready = poll(&pfd, 1, 100);
        if (ready > 0)
            wl_display_read_events(display);
        else
            wl_display_cancel_read(display);
        if (wl_display_dispatch_pending(display) == -1)
            return;
    }
    running = false;
}

int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--static-ms") == 0 && i + 1 < argc)
            static_ms = atoi(argv[++i]);
        else if (strcmp(argv[i], "--damage-ms") == 0 && i + 1 < argc)
            damage_ms = atoi(argv[++i]);
    }

    display = wl_display_connect(NULL);
    if (!display) {
        fprintf(stderr, "wl_display_connect failed\n");
        return 1;
    }
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    wl_display_roundtrip(display);
    if (!compositor || !shm || !wm_base) {
        fprintf(stderr, "missing compositor, shm, or xdg_wm_base\n");
        return 1;
    }
    xdg_wm_base_add_listener(wm_base, &wm_base_listener, NULL);
    buffer = create_buffer();
    surface = wl_compositor_create_surface(compositor);
    xdg_surface = xdg_wm_base_get_xdg_surface(wm_base, surface);
    xdg_surface_add_listener(xdg_surface, &xdg_surface_listener, NULL);
    struct xdg_toplevel *toplevel = xdg_surface_get_toplevel(xdg_surface);
    xdg_toplevel_add_listener(toplevel, &toplevel_listener, NULL);
    xdg_toplevel_set_title(toplevel, "frame-timer");
    xdg_toplevel_set_app_id(toplevel, "frame-timer");
    xdg_toplevel_set_fullscreen(toplevel, NULL);
    wl_surface_commit(surface);

    while (!configured) {
        if (wl_display_dispatch(display) == -1)
            return 1;
    }

    phase = 0;
    run_phase();
    dump_phase("static");

    phase = 1;
    run_phase();
    dump_phase("damage");
    return 0;
}
