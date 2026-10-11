# aquamarine-swrender

Unofficial notes and patches for running Hyprland 0.56.2 with Aquamarine 0.15.1 on a machine that has no GPU and no `/dev/dri`. This repository does not vendor either project. It is not affiliated with hyprwm, and nothing here has been submitted upstream.

The patches are derived from Hyprland and Aquamarine. Both of those projects use the BSD 3-Clause license, and the patches stay under that license. Scripts, docs, and `clients/shm-window.c` in this repository are also BSD 3-Clause. See [LICENSE](LICENSE). The vendored pstack skills under `.cursor/` are MIT, Copyright (c) 2026 Lauren Tan. That notice is [.cursor/PSTACK-LICENSE](.cursor/PSTACK-LICENSE). The pin is recorded in [.cursor/PSTACK-VENDOR.md](.cursor/PSTACK-VENDOR.md).

## Status

The headless path works on this VM. Hyprland starts with an shm allocator and surfaceless EGL on llvmpipe, creates output `HEADLESS-1`, and grim can capture it.

Three proofs are in `proof/`.

- `proof/hyprland-headless.png` is the empty desktop.
- `proof/hyprland-headless-client.png` is an xdg-shell window painted with `wl_shm`.
- `proof/hyprland-headless-foot.png` is foot 1.16.2. The left pane runs `neofetch --stdout` after `fastfetch` fails, then `ls -l /dev/dri`, an `lspci` GPU query, and a filtered `eglinfo -B`. The right pane runs `hyprctl monitors` and `hyprctl version`. The capture script is [scripts/proof-terminal.sh](scripts/proof-terminal.sh).

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

With no DRM fd the compositor does not advertise `zwp_linux_dmabuf_v1` or `wl_drm`. Foot's buffers in the proof were `wl_shm`.

## Limits

There is no pixman renderer and no udmabuf path. Xwayland is configured off, and the Xwayland sources still compile. Input is untested. The monitor rule asks for 1920x1080 at 60 Hz. That number is the mode request, not a measured frame rate. `foot` is not built by `scripts/build.sh`. The foot proof also needs `neofetch`, `pciutils`, and `mesa-utils` on the host.

`CMonitorState::ensureBufferPresent` returns early only when the pending buffer is a dmabuf whose fourcc matches `m_drmFormat`. The headless swapchain buffers are shm. `CSHMBuffer` stores `DRM_FORMAT_XRGB8888` (the log names it XR24), so `dmabuf().success` is false. Each `commit()` and each `test()` then logs `no buffer or mismatched format, attaching one from the swapchain for modeset being possible`, attaches `swapchain->next(nullptr)`, and calls `rollback()`. One `grim -o HEADLESS-1` of the empty desktop logged that line 73 times. The Hyprland patch now also returns early when `shm().success` is set and `shm().format` matches `m_drmFormat`. The same capture then logged the line once, on the first mode test, before any buffer was pending. Later commits kept the shm buffer, and grim still wrote a 1920x1080 PNG.
