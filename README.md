# aquamarine-swrender

Unofficial notes and patches for running Hyprland 0.56.2 with Aquamarine 0.15.1 on a machine that has no GPU and no `/dev/dri`. This repository does not vendor either project. It is not affiliated with hyprwm, and nothing here has been submitted upstream.

The patches are derived from Hyprland and Aquamarine. Both of those projects use the BSD 3-Clause license, and the patches stay under that license. Scripts, docs, and `clients/shm-window.c` in this repository are also BSD 3-Clause. See [LICENSE](LICENSE). The vendored pstack skills under `.cursor/` are MIT, Copyright (c) 2026 Lauren Tan. That notice is [.cursor/PSTACK-LICENSE](.cursor/PSTACK-LICENSE). The pin is recorded in [.cursor/PSTACK-VENDOR.md](.cursor/PSTACK-VENDOR.md).

## Status

The headless path works on this VM. Hyprland starts with an shm allocator and surfaceless EGL on llvmpipe, creates output `HEADLESS-1`, and grim can capture it.

Three proofs are in `proof/`.

- `proof/hyprland-headless.png` is the empty desktop.
- `proof/hyprland-headless-client.png` is an xdg-shell window painted with `wl_shm`.
- `proof/hyprland-headless-foot.png` is foot 1.16.2 showing `uname -a` and the line `CPU-only Hyprland`.

Background is in [docs/PRIOR-ART.md](docs/PRIOR-ART.md) and [docs/FEASIBILITY.md](docs/FEASIBILITY.md). A small surfaceless EGL probe is in [experiments/](experiments/).

## Reproduce

`scripts/build.sh` rebuilds the pinned tags into `.build/prefix`. That directory is gitignored. The script does not install anything under `/usr`.

Hyprland is `efb50993780079460b0cbed1363e2166a2de1d9f`. Aquamarine is `f31c47a1b9d300847d8fc3108ad959448103dfc1`. This tree needs gcc 15, CMake 3.31 or newer, and Meson 1.4 or newer. `scripts/build.sh` downloads CMake 3.31.8 and uses `gcc-15` and `g++-15`. The build that produced the proofs ran on Ubuntu 24.04.5 with gcc 15.2.0, CMake 3.31.8, and Meson 1.12.1. A single clean timing of the whole prefix was not recorded.

```bash
./scripts/build.sh
./scripts/run-headless.sh proof/hyprland-headless.png
./scripts/run-headless.sh --client
./scripts/run-headless.sh --terminal
```

`run-headless.sh` exits if `/dev/dri` exists. It sets `LIBGL_ALWAYS_SOFTWARE=1` and `GALLIUM_DRIVER=llvmpipe`, starts Hyprland through `start-hyprland` with `scripts/headless.lua`, waits for a Wayland socket, and runs `grim -o HEADLESS-1`. `--client` builds `clients/shm-window.c` and waits until `hyprctl clients` lists `shm-window`. `--terminal` runs the system `foot` package with `uname -a` and the line `CPU-only Hyprland`, then waits until `hyprctl clients` lists `foot`.

With no DRM fd the compositor does not advertise `zwp_linux_dmabuf_v1` or `wl_drm`. Foot's buffers in the proof were `wl_shm`.

## Limits

There is no pixman renderer and no udmabuf path. Xwayland is configured off, and the Xwayland sources still compile. Input is untested. The monitor rule asks for 1920x1080 at 60 Hz. That number is the mode request, not a measured frame rate. During screencopy the log repeats `ensureBufferPresent` many times. The captured frames were still intact. `foot` is not built by `scripts/build.sh`. Install it separately.
