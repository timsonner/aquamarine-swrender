# CPU-only Hyprland notes

Notes on running Hyprland 0.56.2 / Aquamarine 0.15.1 with no DRM device and no GPU. This repository is the research record for that question. It does not vendor Hyprland.

- [docs/PRIOR-ART.md](docs/PRIOR-ART.md) — issues, maintainer comments, CI, and how wlroots headless + pixman does it.
- [docs/FEASIBILITY.md](docs/FEASIBILITY.md) — GBM/DRM dependency map, surfaceless EGL results from this VM, MVP patch plan, go recommendation.
- [experiments/](experiments/) — a small surfaceless EGL + GLES probe. Build instructions are in [experiments/README.md](experiments/README.md).

## Reproduce the headless screenshot

The patches and scripts rebuild Hyprland 0.56.2 (`efb50993780079460b0cbed1363e2166a2de1d9f`) and Aquamarine 0.15.1 (`f31c47a1b9d300847d8fc3108ad959448103dfc1`) into `.build/prefix`. The prefix is gitignored. Nothing is installed under `/usr`.

This VM has no `/dev/dri`. The build ran on the VM with gcc 15.2.0, CMake 3.31.8, and Meson 1.12.1. Ubuntu's default gcc 13 and CMake 3.28 cannot build this tree. `scripts/build.sh` downloads CMake 3.31.8 and uses `gcc-15` / `g++-15`.

```bash
./scripts/build.sh
./scripts/run-headless.sh proof/hyprland-headless.png
```

`run-headless.sh` refuses to start if `/dev/dri` exists. It sets `LIBGL_ALWAYS_SOFTWARE=1` and `GALLIUM_DRIVER=llvmpipe`, waits for a Wayland socket, and runs `grim -o HEADLESS-1`. A successful run writes a 1920x1080 PNG. The checked-in shot is that output. The log line `Software renderer from GL_RENDERER: llvmpipe` and `shm: created an allocator` are the matching compositor evidence.

The committed proof was produced from the prefix already on this machine. A later incremental link of `Renderer.cpp` took 14 seconds. A single clean timing of the whole prefix was not recorded, because earlier `scripts/build.sh` runs stopped on missing packages and were resumed.
