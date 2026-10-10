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

Hyprland is `efb50993780079460b0cbed1363e2166a2de1d9f`. Aquamarine is `f31c47a1b9d300847d8fc3108ad959448103dfc1`. This tree needs gcc 15, CMake 3.31 or newer, and Meson 1.4 or newer. `scripts/build.sh` downloads CMake 3.31.8 and uses `gcc-15` and `g++-15`. The build that produced the proofs ran on Ubuntu 24.04.5 with gcc 15.2.0, CMake 3.31.8, and Meson 1.12.1. A single clean timing of the whole prefix was not recorded.

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

There is no pixman renderer and no udmabuf path. Xwayland is configured off, and the Xwayland sources still compile. Input is untested. The monitor rule asks for 1920x1080 at 60 Hz. That number is the mode request, not a measured frame rate. During screencopy the log repeats `ensureBufferPresent` many times. The captured frames were still intact. `foot` is not built by `scripts/build.sh`. The foot proof also needs `neofetch`, `pciutils`, and `mesa-utils` on the host.
