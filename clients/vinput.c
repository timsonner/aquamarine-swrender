#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <linux/input-event-codes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>

#include "virtual-keyboard-unstable-v1-client-protocol.h"
#include "wlr-virtual-pointer-unstable-v1-client-protocol.h"

static struct wl_display *display;
static struct wl_seat *seat;
static struct zwp_virtual_keyboard_manager_v1 *keyboard_manager;
static struct zwp_virtual_keyboard_v1 *keyboard;
static struct zwlr_virtual_pointer_manager_v1 *pointer_manager;
static struct zwlr_virtual_pointer_v1 *pointer;
static struct xkb_keymap *keymap;
static uint32_t shift_code;
static uint32_t shift_mask;
static int have_shift;
static uint32_t extent_w = 1920;
static uint32_t extent_h = 1080;

static uint32_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint32_t)(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}

static void registry_global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
    (void)data;
    if (strcmp(interface, wl_seat_interface.name) == 0)
        seat = wl_registry_bind(registry, name, &wl_seat_interface, 1);
    else if (strcmp(interface, zwp_virtual_keyboard_manager_v1_interface.name) == 0)
        keyboard_manager = wl_registry_bind(registry, name, &zwp_virtual_keyboard_manager_v1_interface, 1);
    else if (strcmp(interface, zwlr_virtual_pointer_manager_v1_interface.name) == 0) {
        uint32_t ver = version < 2 ? version : 2;
        pointer_manager = wl_registry_bind(registry, name, &zwlr_virtual_pointer_manager_v1_interface, ver);
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

static int find_key(xkb_keysym_t want, int *need_shift, uint32_t *evdev_out) {
    xkb_keycode_t min = xkb_keymap_min_keycode(keymap);
    xkb_keycode_t max = xkb_keymap_max_keycode(keymap);
    for (int level = 0; level < 2; level++) {
        for (xkb_keycode_t kc = min; kc <= max; kc++) {
            const xkb_keysym_t *syms = NULL;
            int n = xkb_keymap_key_get_syms_by_level(keymap, kc, 0, level, &syms);
            if (n == 1 && syms && syms[0] == want) {
                *need_shift = level > 0;
                *evdev_out = (uint32_t)kc - 8;
                return 1;
            }
        }
    }
    return 0;
}

static void send_key(uint32_t code, int pressed) {
    zwp_virtual_keyboard_v1_key(keyboard, now_ms(), code, pressed ? 1 : 0);
    wl_display_flush(display);
    usleep(12000);
}

static void send_mods(uint32_t depressed) {
    zwp_virtual_keyboard_v1_modifiers(keyboard, depressed, 0, 0, 0);
    wl_display_flush(display);
    usleep(8000);
}

static void type_text(const char *text) {
    for (const unsigned char *p = (const unsigned char *)text; *p; p++) {
        xkb_keysym_t sym;
        if (*p == '\n')
            sym = XKB_KEY_Return;
        else
            sym = xkb_utf32_to_keysym(*p);
        int need_shift = 0;
        uint32_t code = 0;
        if (sym == XKB_KEY_NoSymbol || !find_key(sym, &need_shift, &code)) {
            fprintf(stderr, "vinput: no key for U+%04X\n", *p);
            exit(1);
        }
        if (need_shift) {
            if (!have_shift) {
                fprintf(stderr, "vinput: keymap has no Shift\n");
                exit(1);
            }
            /* Hyprland forwards these keycodes and only applies the mask from a modifiers request. */
            send_mods(shift_mask);
            send_key(shift_code, 1);
        }
        send_key(code, 1);
        send_key(code, 0);
        if (need_shift) {
            send_key(shift_code, 0);
            send_mods(0);
        }
    }
    wl_display_roundtrip(display);
}

static void check_display(const char *where) {
    int err = wl_display_get_error(display);
    if (err)
        fprintf(stderr, "vinput: display error at %s: %d %s\n", where, err, strerror(err));
}

static void pointer_at(uint32_t x, uint32_t y) {
    zwlr_virtual_pointer_v1_motion_absolute(pointer, now_ms(), x, y, extent_w, extent_h);
    zwlr_virtual_pointer_v1_frame(pointer);
    wl_display_flush(display);
    if (wl_display_roundtrip(display) < 0)
        fprintf(stderr, "vinput: motion roundtrip failed\n");
    check_display("motion");
}

static void pointer_button(int pressed) {
    zwlr_virtual_pointer_v1_button(pointer, now_ms(), BTN_LEFT, pressed ? 1 : 0);
    zwlr_virtual_pointer_v1_frame(pointer);
    wl_display_flush(display);
    if (wl_display_roundtrip(display) < 0)
        fprintf(stderr, "vinput: button roundtrip failed\n");
    check_display("button");
}

static void pointer_drag(uint32_t x1, uint32_t y1, uint32_t x2, uint32_t y2) {
    /* The first warp can be consumed by wl_pointer.enter. Repeat it so the
       press lands on the coordinates the client has already seen. */
    pointer_at(x1, y1);
    usleep(20000);
    pointer_at(x1, y1);
    usleep(20000);
    pointer_button(1);
    for (int i = 1; i <= 8; i++) {
        uint32_t x = x1 + (x2 - x1) * (uint32_t)i / 8;
        uint32_t y = y1 + (y2 - y1) * (uint32_t)i / 8;
        pointer_at(x, y);
        usleep(15000);
    }
    pointer_button(0);
}

static void wait_for_env_file(const char *env_name) {
    const char *path = getenv(env_name);
    if (!path || !path[0])
        return;
    for (int i = 0; i < 400; i++) {
        if (access(path, F_OK) == 0)
            return;
        usleep(50000);
    }
    fprintf(stderr, "vinput: timed out waiting for %s (%s)\n", env_name, path);
    exit(1);
}

static void setup_keymap(void) {
    struct xkb_context *ctx = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    if (!ctx) {
        fprintf(stderr, "vinput: xkb_context_new failed\n");
        exit(1);
    }
    struct xkb_rule_names names = {.rules = "evdev", .model = "pc105", .layout = "us"};
    keymap = xkb_keymap_new_from_names(ctx, &names, XKB_KEYMAP_COMPILE_NO_FLAGS);
    xkb_context_unref(ctx);
    if (!keymap) {
        fprintf(stderr, "vinput: failed to compile a us keymap\n");
        exit(1);
    }
    char *text = xkb_keymap_get_as_string(keymap, XKB_KEYMAP_FORMAT_TEXT_V1);
    if (!text) {
        fprintf(stderr, "vinput: keymap string failed\n");
        exit(1);
    }
    size_t len = strlen(text);
    int fd = memfd_create("vinput-keymap", MFD_CLOEXEC);
    if (fd < 0 || write(fd, text, len) != (ssize_t)len) {
        perror("keymap");
        exit(1);
    }
    free(text);
    if (!seat) {
        fprintf(stderr, "vinput: compositor has no wl_seat\n");
        exit(1);
    }
    keyboard = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(keyboard_manager, seat);
    zwp_virtual_keyboard_v1_keymap(keyboard, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, (uint32_t)len);
    close(fd);
    wl_display_roundtrip(display);
    int unused = 0;
    if (!find_key(XKB_KEY_Shift_L, &unused, &shift_code)) {
        fprintf(stderr, "vinput: keymap has no left shift\n");
        exit(1);
    }
    xkb_mod_index_t shift_index = xkb_keymap_mod_get_index(keymap, XKB_MOD_NAME_SHIFT);
    if (shift_index == XKB_MOD_INVALID) {
        fprintf(stderr, "vinput: keymap has no Shift modifier\n");
        exit(1);
    }
    shift_mask = 1u << shift_index;
    have_shift = 1;
    /* Give the focused client a moment to install the keymap before the first key. */
    wl_display_roundtrip(display);
    usleep(40000);
}

static void usage(void) {
    fprintf(stderr,
            "usage: vinput [--extent W H] type TEXT\n"
            "       vinput [--extent W H] click X Y\n"
            "       vinput [--extent W H] drag X1 Y1 X2 Y2\n");
}

int main(int argc, char **argv) {
    int argi = 1;
    if (argi < argc && strcmp(argv[argi], "--extent") == 0) {
        if (argi + 2 >= argc) {
            usage();
            return 2;
        }
        extent_w = (uint32_t)atoi(argv[argi + 1]);
        extent_h = (uint32_t)atoi(argv[argi + 2]);
        argi += 3;
    }
    if (argi >= argc) {
        usage();
        return 2;
    }
    const char *cmd = argv[argi++];

    display = wl_display_connect(NULL);
    if (!display) {
        fprintf(stderr, "vinput: wl_display_connect failed\n");
        return 1;
    }
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    wl_display_roundtrip(display);

    if (strcmp(cmd, "type") == 0) {
        if (argi >= argc || !keyboard_manager) {
            fprintf(stderr, "vinput: type needs text and zwp_virtual_keyboard_manager_v1\n");
            return 1;
        }
        setup_keymap();
        /* Set by the input test so keys are sent only after the client has the keymap and focus. */
        wait_for_env_file("VINPUT_WAIT_BOUND");
        type_text(argv[argi]);
    } else if (strcmp(cmd, "click") == 0 || strcmp(cmd, "drag") == 0) {
        if (!pointer_manager) {
            fprintf(stderr, "vinput: compositor has no zwlr_virtual_pointer_manager_v1\n");
            return 1;
        }
        pointer = zwlr_virtual_pointer_manager_v1_create_virtual_pointer(pointer_manager, NULL);
        /* The new pointer updates seat capabilities. Clients bind wl_pointer
           during this roundtrip. Motion sent before that is not delivered. */
        wl_display_roundtrip(display);
        /* Set by the input test so the click waits until that bind has completed. */
        wait_for_env_file("VINPUT_WAIT_POINTER");
        if (strcmp(cmd, "click") == 0) {
            if (argi + 1 >= argc) {
                usage();
                return 2;
            }
            uint32_t x = (uint32_t)atoi(argv[argi]);
            uint32_t y = (uint32_t)atoi(argv[argi + 1]);
            pointer_at(x, y);
            usleep(30000);
            pointer_button(1);
            usleep(30000);
            pointer_button(0);
        } else {
            if (argi + 3 >= argc) {
                usage();
                return 2;
            }
            pointer_drag((uint32_t)atoi(argv[argi]), (uint32_t)atoi(argv[argi + 1]), (uint32_t)atoi(argv[argi + 2]),
                         (uint32_t)atoi(argv[argi + 3]));
        }
    } else {
        usage();
        return 2;
    }
    wl_display_roundtrip(display);
    return 0;
}
