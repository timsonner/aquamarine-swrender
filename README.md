# aquamarine-swrender

Unofficial notes and patches for running Hyprland 0.56.2 with Aquamarine 0.15.1 on a machine that has no GPU and no `/dev/dri`. This repository does not vendor either project. It is not affiliated with hyprwm, and nothing here has been submitted upstream.

The patches are derived from Hyprland and Aquamarine. Both of those projects use the BSD 3-Clause license, and the patches stay under that license. Scripts, docs, and the C clients under `clients/` in this repository are also BSD 3-Clause. See [LICENSE](LICENSE). `clients/virtual-keyboard-unstable-v1.xml` and `clients/wlr-virtual-pointer-unstable-v1.xml` keep the MIT notices in those files. The vendored pstack skills under `.cursor/` are MIT, Copyright (c) 2026 Lauren Tan. That notice is [.cursor/PSTACK-LICENSE](.cursor/PSTACK-LICENSE). The pin is recorded in [.cursor/PSTACK-VENDOR.md](.cursor/PSTACK-VENDOR.md).

## Status

The headless path works on this VM. Hyprland starts with an shm allocator and surfaceless EGL on llvmpipe, creates output `HEADLESS-1`, and grim can capture it.

The proofs are in `proof/`.

- `proof/hyprland-headless.png` is the empty desktop.
- `proof/hyprland-headless-client.png` is an xdg-shell window painted with `wl_shm`.
- `proof/hyprland-headless-foot.png` is foot 1.16.2. The left pane runs `neofetch --stdout` after `fastfetch` fails, then `ls -l /dev/dri`, an `lspci` GPU query, and a filtered `eglinfo -B`. The right pane runs `hyprctl monitors` and `hyprctl version`. The capture script is [scripts/proof-terminal.sh](scripts/proof-terminal.sh).
- `proof/hyprland-headless-input.png` is foot after a virtual keyboard types `echo KEYBOARD-OK-7741` and a virtual pointer drag-selects the output. The capture script is [scripts/proof-input.sh](scripts/proof-input.sh).

Background is in [docs/PRIOR-ART.md](docs/PRIOR-ART.md) and [docs/FEASIBILITY.md](docs/FEASIBILITY.md). A small surfaceless EGL probe is in [experiments/](experiments/).

## Reproduce

`scripts/build.sh` rebuilds the pinned tags into `.build/prefix`. That directory is gitignored, along with cloned upstream trees, other build directories, the install prefix, the runtime directory, logs, editor files, and PNG files outside `proof/`. The screenshots in `proof/` stay tracked. The script does not install anything under `/usr`.

Hyprland is `efb50993780079460b0cbed1363e2166a2de1d9f`. Aquamarine is `f31c47a1b9d300847d8fc3108ad959448103dfc1`. This tree needs gcc 15, CMake 3.31 or newer, and Meson 1.4 or newer. `scripts/build.sh` downloads CMake 3.31.8 and uses `gcc-15` and `g++-15`. Ubuntu 24.04's Meson is 1.3.2, so the script installs `meson>=1.7` with `pip install --user` when the `meson` on `PATH` is older than 1.4. wayland-protocols 1.49 marks interfaces `frozen="true"`. wayland-scanner 1.24.0 rejects that attribute, so the script builds wayland 1.25.0 when `wayland-server` is older than 1.25. `scripts/pkgconfig/pkg-config` is placed first on `PATH` and moves this prefix's `-L` flags ahead of `/usr`. Without that, CMake's `PKG_CONFIG_ALLOW_SYSTEM_LIBS` keeps `-L/usr` first and `find_library` binds the older system `libinput` and `libdisplay-info`.

### Clean build timing

One clean run, `rm -rf .build && ./scripts/build.sh`, on this VM. `scripts/build.sh` prints the same table and writes `.build/build-timings.tsv`. `JOBS` was the script default, 2. The compiler line from that run was `gcc-15 (Ubuntu 15.2.0-14ubuntu1~24~ppa1) 15.2.0`. CMake was 3.31.8. Meson was 1.12.1 from `~/.local/bin`, already installed, so the meson stage is the version check rather than a pip install. wayland-server from the prefix was 1.25.0.

The machine was Ubuntu 24.04.5 LTS, Linux 6.12.94+ x86_64, a KVM guest. `lscpu` reported 4 CPUs, Intel Xeon model 207, BogoMIPS 4800.00. `MemTotal` was 16398384 kB (16791945216 bytes). `/dev/dri` was absent.

Wall-clock total: 861.912 seconds.

| Stage | Seconds |
| --- | ---: |
| cmake | 1.428 |
| meson | 0.223 |
| wayland | 4.256 |
| wayland-protocols | 2.151 |
| libxkbcommon | 11.037 |
| libinput | 6.263 |
| lua | 3.351 |
| hyprutils | 13.954 |
| hyprwayland-scanner | 5.886 |
| hyprlang | 7.019 |
| hyprcursor | 11.545 |
| hyprgraphics | 11.838 |
| hyprland-protocols | 0.521 |
| hyprwire | 22.239 |
| libdisplay-info | 2.306 |
| aquamarine | 40.459 |
| hyprland | 713.411 |
| grim | 3.542 |
| shm-window | 0.152 |
| total | 861.912 |

```bash
./scripts/build.sh
./scripts/run-headless.sh proof/hyprland-headless.png
./scripts/run-headless.sh --client
./scripts/proof-terminal.sh
```

`run-headless.sh --terminal` runs `scripts/proof-terminal.sh`. That script is what produced `proof/hyprland-headless-foot.png`.

`run-headless.sh` exits if `/dev/dri` exists. It sets `LIBGL_ALWAYS_SOFTWARE=1` and `GALLIUM_DRIVER=llvmpipe`, starts Hyprland through `start-hyprland` with `scripts/headless.lua`, waits for a Wayland socket, and runs `grim -o HEADLESS-1`. `--client` builds `clients/shm-window.c` and waits until `hyprctl clients` lists `shm-window`.

`proof-terminal.sh` uses the same environment and a tighter gap setting so two foot windows fit in the 1920x1080 frame at 13px. It waits until each pane is tall enough, then runs the commands below. Bash `set -x` prints the commands in the shot. Install `foot`, `neofetch`, `pciutils`, and `mesa-utils` separately. `fastfetch` is not in Ubuntu 24.04 apt, so the left pane shows `fastfetch: command not found` and then `neofetch --stdout`.

Left pane:

- `fastfetch`, which errors, then `neofetch --stdout`
- `ls -l /dev/dri`, which errors because the directory is absent
- `lspci -nn | grep -Ei 'vga|3d|display' || echo 'no GPU'`
- `eglinfo -B 2>&1 | grep -E 'platform:|eglInitialize|renderer:'`

On this VM the grep keeps the platform headers, the GBM and X11 `eglInitialize failed` lines, and the renderer lines. Wayland, Surfaceless, and the device platform report `llvmpipe (LLVM 20.1.2, 256 bits)`. `eglinfo` itself exits non-zero when a platform fails. The script turns off `pipefail` for that pipeline so a successful grep is not reported as a miss.

Right pane:

- `hyprctl monitors`, including `HEADLESS-1`, `1920x1080@60`, and `currentFormat: XRGB8888`
- `hyprctl version`

With no DRM fd the compositor does not advertise `zwp_linux_dmabuf_v1` or `wl_drm`. Foot's buffers in the proof were `wl_shm`. llvmpipe still fills the EGL dmabuf format list. MEASURED on this VM: one headless startup logged `EGL: 69 formats found in total` and `ProtocolManager: no DRM fd, not advertising linux-dmabuf or wl_drm`. Grim 1.5.0's `WAYLAND_DEBUG` registry on that session listed neither `zwp_linux_dmabuf_v1` nor `wl_drm`.

## Frame timing

`scripts/measure-fps.sh` rebuilds `clients/frame-timer.c` and runs it on `HEADLESS-1` with `LIBGL_ALWAYS_SOFTWARE=1` and `GALLIUM_DRIVER=llvmpipe`. The client is a fullscreen xdg-shell surface, 1280x720, `WL_SHM_FORMAT_ARGB8888`. It has two phases. The static phase damages the buffer once, then keeps requesting `wl_surface.frame` and committing without further damage for 3000 ms. The damage phase is the animating client: it repaints and damages the whole buffer on every callback for 5000 ms. Each phase is a fixed window (`--static-ms`, `--damage-ms`). Intervals are `CLOCK_MONOTONIC` deltas between consecutive callbacks. Frames per second are `(frames - 1) / elapsed_seconds`. Percentiles use the sorted intervals, index `round((n - 1) * p)`.

```bash
scripts/measure-fps.sh [--static-ms N] [--damage-ms N]
```

| Exit | Meaning |
| --- | --- |
| 0 | The damage phase printed fps, p50, p95, and max |
| 1 | The compositor died, the client build failed, or the arguments are wrong |
| 2 | The client finished and the damage phase has too few frames for a distribution |

The script refuses to start when `/dev/dri` exists. It creates a private runtime directory and a private `HOME` with `mktemp`, ignores any inherited `XDG_RUNTIME_DIR`, refuses a path under `/run/user`, and on exit signals only the process groups it started.

Aquamarine's headless backend schedules the next frame from the current mode. `hyprctl monitors` on this run reported `1920x1080@60.00000`, `currentFormat: XRGB8888`, and `vrr: false`. At 60000 mHz the interval is `1000 * 10^9 / 60000` nanoseconds, 16.667 ms. If the deadline has already passed, the callback is queued as an idle event.

One run of `./scripts/measure-fps.sh`:

| Phase | Frames | Elapsed | FPS | Interval min | mean | p50 | p95 | max |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| static | 176 | 3.008135 s | 58.176 | 6.149 ms | 17.189 ms | 16.670 ms | 18.257 ms | 101.941 ms |
| damage | 302 | 5.013910 s | 60.033 | 14.581 ms | 16.658 ms | 16.642 ms | 18.036 ms | 18.864 ms |

The static mean sits above the p50 because one interval was 101.941 ms.

## Input

`scripts/proof-input.sh` opens foot in the headless session and drives it with `clients/vinput.c`. The shot is `proof/hyprland-headless-input.png`. The client binds `zwp_virtual_keyboard_v1` and `zwlr_virtual_pointer_v1`. It types `echo KEYBOARD-OK-7741` and Enter. The next line is that command's output, and a left-button drag selects it. The white selection in the shot is the click.

Hyprland forwards virtual-keyboard keycodes and applies modifiers from the modifiers request, so Shift is sent as Left Shift and as the Shift mask. The keymap is xkb `evdev` / `pc105` / `us`. Creating the virtual pointer adds the pointer bit to the seat. The client round-trips once before the first warp so foot can bind `wl_pointer`. On this run the first warp was consumed by `wl_pointer.enter` at `-1, -1`, so the client warps to the selection start a second time before pressing `BTN_LEFT`.

`/dev/uinput` does not exist here, so ydotool cannot open a kernel device. `wtype --help` prints `Missing argument to --help` and exits. The headless backend's `setCursor` returns false. The I-beam in the shot is the cursor foot set, drawn into the frame grim captured.

`scripts/test-input.sh` is the automated check for the same path. It does not launch another application's terminal. It maps `clients/input-sink`, an xdg-shell `wl_shm` window, and drives it with `clients/vinput.c`. The sink binds `wl_keyboard` when the seat grows a keyboard and writes a ready file after the keymap and `wl_keyboard.enter` have both arrived. `vinput type` waits for that file, then types the text. The sink binds `wl_pointer` when the virtual pointer appears, round-trips the bind, and writes a second ready file. `vinput drag` waits for that file, then presses `BTN_LEFT` at the center of the window. The sink exits 0 only after `xkb_state_key_get_utf8` has produced the expected text and a left button press has been delivered. The click is placed inside the 640x360 buffer at the top left of the tiled window.

```bash
scripts/test-input.sh [--timeout SEC] [--text STRING] [--no-window] [--no-keys] [--no-click]
```

`INPUT_TIMEOUT` (default 20) is how long the script waits for the window to show up in `hyprctl clients`. `INPUT_TEXT` (default `KEYBOARD-OK-7741`) is the string the sink must decode. `--no-window` starts the compositor and does not map a client. `--no-keys` maps the client and does not type. `--no-click` types the text and does not press the button. The script refuses to start when `/dev/dri` exists. It creates a private runtime directory and a private `HOME` with `mktemp`, ignores any inherited `XDG_RUNTIME_DIR`, and on exit signals only the process groups it started.

| Exit | Meaning |
| --- | --- |
| 0 | The client decoded the text and received a left button press |
| 1 | The compositor died, the client build failed, or the arguments are wrong |
| 2 | No mapped window before the timeout |
| 4 | A window mapped and the text never arrived |
| 5 | The text arrived and no left button did |

MEASURED: `./scripts/test-input.sh` exited 0. The client printed `input-sink status=pass text=KEYBOARD-OK-7741 buttons=1 motions=1 code=0`. The click was 248,208. `./scripts/test-input.sh --timeout 3 --no-window` exited 2 (`no-window`, `no open windows`). `./scripts/test-input.sh --timeout 12 --no-keys` exited 4 (`input-sink status=no-keyboard text= buttons=0 motions=0 code=4`). `./scripts/test-input.sh --timeout 12 --no-click` exited 5 (`input-sink status=no-pointer text=KEYBOARD-OK-7741 buttons=0 motions=0 code=5`). `./scripts/test-input.sh --nope` exited 1. After each run, no `Hyprland` process and no `/tmp/hypr-rt.*` directory remained.

## Smoke

`scripts/smoke-app.sh` launches one command inside the headless session, waits until `hyprctl clients -j` lists a mapped window, takes `grim -o HEADLESS-1`, and measures the population variance of Rec. 709 luminance in that window's rectangle (`at` and `size`). A crop larger than 250000 pixels is sampled on a stride of 2.

```bash
scripts/smoke-app.sh [--timeout SEC] [--shot PATH] [--min-variance N] [--class NAME] -- CMD [ARGS...]
```

`--class` keeps a client whose class, initial class, or title contains that string. The same values can be set with `SMOKE_TIMEOUT` (default 20), `SMOKE_SHOT` (default `.build/smoke-app.png`), and `SMOKE_MIN_VARIANCE` (default 25). The script refuses to start when `/dev/dri` exists. It uses the same private runtime, private `HOME`, and process-group cleanup as `scripts/test-input.sh`.

| Exit | Meaning |
| --- | --- |
| 0 | A mapped window's crop is at or above the variance threshold |
| 1 | The compositor died, grim failed, the PNG could not be read, or the arguments are wrong |
| 2 | No mapped window before the timeout |
| 3 | A window mapped and the crop is under the variance threshold |

On this VM, MEASURED again: `scripts/smoke-app.sh` with no arguments exited 1. `scripts/smoke-app.sh --timeout 2 -- true` exited 2. `scripts/smoke-app.sh --timeout 20 --class shm-window -- .build/prefix/bin/shm-window` exited 0 with variance 1726.1557, 394144 samples, on a 1744x904 crop at 88,88. The same command with `--min-variance 1000000` exited 3 with variance 1791.9980. Replacing `grim` with a program that exits 1 made the script exit 1 and print `grim-failed`. `grim` was restored afterward.

## Limits

There is no pixman renderer and no udmabuf path. Xwayland is configured off, and the Xwayland sources still compile. `foot` is not built by `scripts/build.sh`. The foot proof also needs `neofetch`, `pciutils`, and `mesa-utils` on the host.

`CMonitorState::ensureBufferPresent` returns early only when the pending buffer is a dmabuf whose fourcc matches `m_drmFormat`. The headless swapchain buffers are shm. `CSHMBuffer` stores `DRM_FORMAT_XRGB8888` (the log names it XR24), so `dmabuf().success` is false. Each `commit()` and each `test()` then logs `no buffer or mismatched format, attaching one from the swapchain for modeset being possible`, attaches `swapchain->next(nullptr)`, and calls `rollback()`. The count is one line per `commit()` or `test()`, so it moves with how many frames land before grim returns. MEASURED on this VM with `debug.enable_stdout_logs = true` (stdout is flushed; the instance file log is not) and `grim -o HEADLESS-1` after one second: the unfixed check logged that line 76 times. The Hyprland patch also returns early when `shm().success` is set and `shm().format` matches `m_drmFormat`. The same capture then logged the line once, on the first mode test, before any buffer was pending. Later commits kept the shm buffer. Both PNGs were 1920x1080.

Grim 1.5.0 prefers `ext_image_copy_capture_v1` and does not retry a failed frame on this path. MEASURED, same two captures: one `create_session`, one `ready()`, zero `failed`, and zero `Can't copy` lines. With the shm fix and with `PROTO::linuxDma` still null, the unfixed `sendConstraints` still sent two `dmabuf_format` events (`875713089` ARGB8888 and `875713112` XRGB8888, each `array[16]`) and one `dmabuf_device` (`array[8]`, device 0), plus `shm_format` 0 and 1. The protocol allows zero dmabuf events. The patch skips `sendDmabufFormat` and `sendDmabufDevice` when `PROTO::linuxDma` is null, for both the output session and the cursor session. The same grim trace then had the two `shm_format` events, no `dmabuf_format`, no `dmabuf_device`, and one `ready()`. Grim binds `zwlr_screencopy_manager_v1` at version 1, so it never sees the v3 `linux_dmabuf` hint. That hint is now skipped under the same `PROTO::linuxDma` gate. A live v3 client was not run, so that last gate is UNVERIFIED.
