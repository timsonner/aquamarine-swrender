#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <linux/input-event-codes.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>

#include "xdg-shell-client-protocol.h"

enum { WIDTH = 640, HEIGHT = 360 };

static struct wl_display *display;
static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct wl_seat *seat;
static struct wl_keyboard *keyboard;
static struct wl_pointer *pointer;
static struct xdg_wm_base *wm_base;
static struct wl_surface *surface;
static struct xdg_surface *xdg_surface;
static struct wl_buffer *buffer;
static struct xkb_context *xkb_ctx;
static struct xkb_keymap *xkb_keymap;
static struct xkb_state *xkb_state;
static int configured;
static int got_keymap;
static int got_enter;
static int kb_signaled;
static int pointer_needs_sync;
static int left_presses;
static int motions;
static char text[512];
static size_t text_len;
static const char *expect_text = "KEYBOARD-OK-7741";
static const char *kb_path;
static const char *ptr_path;
static int timeout_sec = 30;

static uint32_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint32_t)(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}

static void write_file(const char *path) {
    if (!path || !path[0])
        return;
    int fd = open(path, O_CREAT | O_WRONLY | O_CLOEXEC, 0644);
    if (fd < 0) {
        perror(path);
        return;
    }
    close(fd);
}

static void append_utf8(const char *s, int n) {
    if (n <= 0)
        return;
    if (text_len + (size_t)n >= sizeof text)
        n = (int)(sizeof text - 1 - text_len);
    if (n <= 0)
        return;
    memcpy(text + text_len, s, (size_t)n);
    text_len += (size_t)n;
    text[text_len] = '\0';
}

static int passed(void) {
    return strstr(text, expect_text) != NULL && left_presses > 0;
}

static void publish_binds(void) {
    if (pointer_needs_sync) {
        pointer_needs_sync = 0;
        if (wl_display_roundtrip(display) < 0)
            fprintf(stderr, "input-sink: pointer bind roundtrip failed\n");
        write_file(ptr_path);
        fprintf(stderr, "input-sink pointer-bound\n");
    }
    if (!kb_signaled && got_keymap && got_enter) {
        write_file(kb_path);
        kb_signaled = 1;
        fprintf(stderr, "input-sink keyboard-bound\n");
    }
}

static void xdg_wm_base_ping(void *data, struct xdg_wm_base *wm, uint32_t serial) {
    (void)data;
    xdg_wm_base_pong(wm, serial);
}

static const struct xdg_wm_base_listener wm_base_listener = {
    .ping = xdg_wm_base_ping,
};

static void xdg_surface_configure(void *data, struct xdg_surface *xdg, uint32_t serial) {
    (void)data;
    xdg_surface_ack_configure(xdg, serial);
    if (!configured) {
        wl_surface_attach(surface, buffer, 0, 0);
        wl_surface_damage_buffer(surface, 0, 0, WIDTH, HEIGHT);
        configured = 1;
        fprintf(stderr, "input-sink mapped\n");
    }
    wl_surface_commit(surface);
}

static const struct xdg_surface_listener xdg_surface_listener = {
    .configure = xdg_surface_configure,
};

static void xdg_toplevel_configure(void *data, struct xdg_toplevel *toplevel, int32_t width, int32_t height,
                                   struct wl_array *states) {
    (void)data;
    (void)toplevel;
    (void)width;
    (void)height;
    (void)states;
}

static void xdg_toplevel_close(void *data, struct xdg_toplevel *toplevel) {
    (void)data;
    (void)toplevel;
    fprintf(stderr, "input-sink closed\n");
    exit(1);
}

static const struct xdg_toplevel_listener toplevel_listener = {
    .configure = xdg_toplevel_configure,
    .close = xdg_toplevel_close,
};

static void keyboard_keymap(void *data, struct wl_keyboard *kb, uint32_t format, int32_t fd, uint32_t size) {
    (void)data;
    (void)kb;
    if (format != WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1) {
        fprintf(stderr, "input-sink: unexpected keymap format %u\n", format);
        close(fd);
        return;
    }
    void *map = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (map == MAP_FAILED) {
        perror("keymap mmap");
        return;
    }
    struct xkb_keymap *next = xkb_keymap_new_from_buffer(xkb_ctx, map, size, XKB_KEYMAP_FORMAT_TEXT_V1, XKB_KEYMAP_COMPILE_NO_FLAGS);
    munmap(map, size);
    if (!next) {
        fprintf(stderr, "input-sink: keymap compile failed\n");
        return;
    }
    if (xkb_state)
        xkb_state_unref(xkb_state);
    if (xkb_keymap)
        xkb_keymap_unref(xkb_keymap);
    xkb_keymap = next;
    xkb_state = xkb_state_new(xkb_keymap);
    got_keymap = 1;
    fprintf(stderr, "input-sink keymap %u bytes\n", size);
}

static void keyboard_enter(void *data, struct wl_keyboard *kb, uint32_t serial, struct wl_surface *entered, struct wl_array *keys) {
    (void)data;
    (void)kb;
    (void)serial;
    (void)entered;
    (void)keys;
    got_enter = 1;
    fprintf(stderr, "input-sink keyboard-enter\n");
}

static void keyboard_leave(void *data, struct wl_keyboard *kb, uint32_t serial, struct wl_surface *left) {
    (void)data;
    (void)kb;
    (void)serial;
    (void)left;
}

static void keyboard_key(void *data, struct wl_keyboard *kb, uint32_t serial, uint32_t time, uint32_t key, uint32_t state) {
    (void)data;
    (void)kb;
    (void)serial;
    (void)time;
    if (!xkb_state)
        return;
    xkb_keycode_t code = key + 8;
    xkb_state_update_key(xkb_state, code, state == WL_KEYBOARD_KEY_STATE_PRESSED ? XKB_KEY_DOWN : XKB_KEY_UP);
    if (state != WL_KEYBOARD_KEY_STATE_PRESSED)
        return;
    char buf[64];
    int n = xkb_state_key_get_utf8(xkb_state, code, buf, sizeof buf);
    if (n > 0)
        append_utf8(buf, n);
    fprintf(stderr, "input-sink key %u utf8=%.*s text=%s\n", key, n > 0 ? n : 0, buf, text);
}

static void keyboard_modifiers(void *data, struct wl_keyboard *kb, uint32_t serial, uint32_t depressed, uint32_t latched,
                               uint32_t locked, uint32_t group) {
    (void)data;
    (void)kb;
    (void)serial;
    if (!xkb_state)
        return;
    xkb_state_update_mask(xkb_state, depressed, latched, locked, 0, 0, group);
}

static void keyboard_repeat_info(void *data, struct wl_keyboard *kb, int32_t rate, int32_t delay) {
    (void)data;
    (void)kb;
    (void)rate;
    (void)delay;
}

static const struct wl_keyboard_listener keyboard_listener = {
    .keymap = keyboard_keymap,
    .enter = keyboard_enter,
    .leave = keyboard_leave,
    .key = keyboard_key,
    .modifiers = keyboard_modifiers,
    .repeat_info = keyboard_repeat_info,
};

static void pointer_enter(void *data, struct wl_pointer *p, uint32_t serial, struct wl_surface *entered, wl_fixed_t x, wl_fixed_t y) {
    (void)data;
    (void)p;
    (void)serial;
    (void)entered;
    fprintf(stderr, "input-sink pointer-enter %d,%d\n", wl_fixed_to_int(x), wl_fixed_to_int(y));
}

static void pointer_leave(void *data, struct wl_pointer *p, uint32_t serial, struct wl_surface *left) {
    (void)data;
    (void)p;
    (void)serial;
    (void)left;
}

static void pointer_motion(void *data, struct wl_pointer *p, uint32_t time, wl_fixed_t x, wl_fixed_t y) {
    (void)data;
    (void)p;
    (void)time;
    motions++;
    fprintf(stderr, "input-sink motion %d,%d\n", wl_fixed_to_int(x), wl_fixed_to_int(y));
}

static void pointer_button(void *data, struct wl_pointer *p, uint32_t serial, uint32_t time, uint32_t button, uint32_t state) {
    (void)data;
    (void)p;
    (void)serial;
    (void)time;
    if (button == BTN_LEFT && state == WL_POINTER_BUTTON_STATE_PRESSED)
        left_presses++;
    fprintf(stderr, "input-sink button %u state %u left=%d\n", button, state, left_presses);
}

static void pointer_axis(void *data, struct wl_pointer *p, uint32_t time, uint32_t axis, wl_fixed_t value) {
    (void)data;
    (void)p;
    (void)time;
    (void)axis;
    (void)value;
}

static void pointer_frame(void *data, struct wl_pointer *p) {
    (void)data;
    (void)p;
}

static void pointer_axis_source(void *data, struct wl_pointer *p, uint32_t source) {
    (void)data;
    (void)p;
    (void)source;
}

static void pointer_axis_stop(void *data, struct wl_pointer *p, uint32_t time, uint32_t axis) {
    (void)data;
    (void)p;
    (void)time;
    (void)axis;
}

static void pointer_axis_discrete(void *data, struct wl_pointer *p, uint32_t axis, int32_t discrete) {
    (void)data;
    (void)p;
    (void)axis;
    (void)discrete;
}

static void pointer_axis_value120(void *data, struct wl_pointer *p, uint32_t axis, int32_t value120) {
    (void)data;
    (void)p;
    (void)axis;
    (void)value120;
}

static void pointer_axis_relative_direction(void *data, struct wl_pointer *p, uint32_t axis, uint32_t direction) {
    (void)data;
    (void)p;
    (void)axis;
    (void)direction;
}

static const struct wl_pointer_listener pointer_listener = {
    .enter = pointer_enter,
    .leave = pointer_leave,
    .motion = pointer_motion,
    .button = pointer_button,
    .axis = pointer_axis,
    .frame = pointer_frame,
    .axis_source = pointer_axis_source,
    .axis_stop = pointer_axis_stop,
    .axis_discrete = pointer_axis_discrete,
    .axis_value120 = pointer_axis_value120,
    .axis_relative_direction = pointer_axis_relative_direction,
};

static void seat_capabilities(void *data, struct wl_seat *s, uint32_t caps) {
    (void)data;
    fprintf(stderr, "input-sink seat caps 0x%x\n", caps);
    if ((caps & WL_SEAT_CAPABILITY_KEYBOARD) && !keyboard) {
        keyboard = wl_seat_get_keyboard(s);
        wl_keyboard_add_listener(keyboard, &keyboard_listener, NULL);
    }
    if ((caps & WL_SEAT_CAPABILITY_POINTER) && !pointer) {
        pointer = wl_seat_get_pointer(s);
        wl_pointer_add_listener(pointer, &pointer_listener, NULL);
        pointer_needs_sync = 1;
    }
}

static void seat_name(void *data, struct wl_seat *s, const char *name) {
    (void)data;
    (void)s;
    fprintf(stderr, "input-sink seat %s\n", name);
}

static const struct wl_seat_listener seat_listener = {
    .capabilities = seat_capabilities,
    .name = seat_name,
};

static void registry_global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
    (void)data;
    if (strcmp(interface, wl_compositor_interface.name) == 0) {
        uint32_t ver = version < 4 ? version : 4;
        compositor = wl_registry_bind(registry, name, &wl_compositor_interface, ver);
    } else if (strcmp(interface, wl_shm_interface.name) == 0) {
        shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
    } else if (strcmp(interface, xdg_wm_base_interface.name) == 0) {
        wm_base = wl_registry_bind(registry, name, &xdg_wm_base_interface, 1);
    } else if (strcmp(interface, wl_seat_interface.name) == 0) {
        uint32_t ver = version < 7 ? version : 7;
        seat = wl_registry_bind(registry, name, &wl_seat_interface, ver);
        wl_seat_add_listener(seat, &seat_listener, NULL);
    }
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

static void paint(uint32_t *pixels) {
    for (int y = 0; y < HEIGHT; y++) {
        for (int x = 0; x < WIDTH; x++) {
            uint32_t color = 0xff202830;
            if (x < 16 || y < 16 || x >= WIDTH - 16 || y >= HEIGHT - 16)
                color = 0xffe07020;
            else if (((x / 32) + (y / 32)) % 2 == 0)
                color = 0xff3a6ea5;
            pixels[y * WIDTH + x] = color;
        }
    }
}

static struct wl_buffer *create_buffer(void) {
    const size_t size = (size_t)WIDTH * HEIGHT * 4;
    int fd = memfd_create("input-sink", MFD_CLOEXEC);
    if (fd < 0) {
        perror("memfd_create");
        exit(1);
    }
    if (ftruncate(fd, (off_t)size) < 0) {
        perror("ftruncate");
        exit(1);
    }
    uint32_t *pixels = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (pixels == MAP_FAILED) {
        perror("mmap");
        exit(1);
    }
    paint(pixels);
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int32_t)size);
    struct wl_buffer *buf = wl_shm_pool_create_buffer(pool, 0, WIDTH, HEIGHT, WIDTH * 4, WL_SHM_FORMAT_ARGB8888);
    wl_shm_pool_destroy(pool);
    close(fd);
    return buf;
}

static int dispatch_once(int remain_ms) {
    while (wl_display_prepare_read(display) != 0) {
        if (wl_display_dispatch_pending(display) < 0)
            return -1;
    }
    if (wl_display_flush(display) < 0 && errno != EAGAIN) {
        wl_display_cancel_read(display);
        return -1;
    }
    struct pollfd pfd = {.fd = wl_display_get_fd(display), .events = POLLIN};
    int rc = poll(&pfd, 1, remain_ms);
    if (rc < 0) {
        if (errno == EINTR) {
            wl_display_cancel_read(display);
            return 0;
        }
        wl_display_cancel_read(display);
        return -1;
    }
    if (rc == 0) {
        wl_display_cancel_read(display);
        return 0;
    }
    if (wl_display_read_events(display) < 0)
        return -1;
    if (wl_display_dispatch_pending(display) < 0)
        return -1;
    return 0;
}

static void report(int code, const char *status) {
    printf("input-sink status=%s text=%s buttons=%d motions=%d code=%d\n", status, text, left_presses, motions, code);
    fflush(stdout);
}

static void usage(void) {
    fprintf(stderr, "usage: input-sink [--text STRING] [--timeout SEC] [--kb-bound PATH] [--ptr-bound PATH]\n");
}

int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--text") == 0 && i + 1 < argc)
            expect_text = argv[++i];
        else if (strcmp(argv[i], "--timeout") == 0 && i + 1 < argc)
            timeout_sec = atoi(argv[++i]);
        else if (strcmp(argv[i], "--kb-bound") == 0 && i + 1 < argc)
            kb_path = argv[++i];
        else if (strcmp(argv[i], "--ptr-bound") == 0 && i + 1 < argc)
            ptr_path = argv[++i];
        else {
            usage();
            return 1;
        }
    }
    if (!expect_text[0] || timeout_sec <= 0) {
        usage();
        return 1;
    }

    xkb_ctx = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    if (!xkb_ctx) {
        fprintf(stderr, "input-sink: xkb_context_new failed\n");
        return 1;
    }

    display = wl_display_connect(NULL);
    if (!display) {
        fprintf(stderr, "input-sink: wl_display_connect failed\n");
        return 1;
    }
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    if (wl_display_roundtrip(display) < 0) {
        fprintf(stderr, "input-sink: registry roundtrip failed\n");
        return 1;
    }
    if (!compositor || !shm || !wm_base || !seat) {
        fprintf(stderr, "input-sink: missing compositor, shm, xdg_wm_base, or seat\n");
        return 1;
    }

    xdg_wm_base_add_listener(wm_base, &wm_base_listener, NULL);
    buffer = create_buffer();
    surface = wl_compositor_create_surface(compositor);
    xdg_surface = xdg_wm_base_get_xdg_surface(wm_base, surface);
    xdg_surface_add_listener(xdg_surface, &xdg_surface_listener, NULL);
    struct xdg_toplevel *toplevel = xdg_surface_get_toplevel(xdg_surface);
    xdg_toplevel_add_listener(toplevel, &toplevel_listener, NULL);
    xdg_toplevel_set_title(toplevel, "input-sink");
    xdg_toplevel_set_app_id(toplevel, "input-sink");
    wl_surface_commit(surface);

    for (int i = 0; i < 50 && !configured; i++) {
        if (wl_display_roundtrip(display) < 0) {
            fprintf(stderr, "input-sink: configure roundtrip failed\n");
            return 1;
        }
    }
    if (!configured) {
        fprintf(stderr, "input-sink: window was not configured\n");
        return 1;
    }
    publish_binds();

    uint32_t start = now_ms();
    uint32_t deadline = start + (uint32_t)timeout_sec * 1000u;
    while (!passed()) {
        uint32_t now = now_ms();
        if (now >= deadline)
            break;
        int remain = (int)(deadline - now);
        if (remain > 200)
            remain = 200;
        if (dispatch_once(remain) < 0) {
            fprintf(stderr, "input-sink: display disconnected\n");
            report(1, "disconnected");
            return 1;
        }
        publish_binds();
    }

    if (passed()) {
        report(0, "pass");
        return 0;
    }
    if (strstr(text, expect_text) != NULL) {
        report(5, "no-pointer");
        return 5;
    }
    report(4, "no-keyboard");
    return 4;
}
