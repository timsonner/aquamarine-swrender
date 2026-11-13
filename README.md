# aquamarine-swrender

Unofficial patches and scripts for running Hyprland 0.56.2 (`efb50993780079460b0cbed1363e2166a2de1d9f`) and Aquamarine 0.15.1 (`f31c47a1b9d300847d8fc3108ad959448103dfc1`) on a machine with no GPU and no `/dev/dri`. `scripts/build.sh` clones those pins, applies the shm allocator and surfaceless EGL patches, and installs a private prefix so Hyprland can start output `HEADLESS-1` on llvmpipe and `grim` can capture it. This repository does not vendor either project and is not affiliated with hyprwm.

## Prerequisites

- A machine where `/dev/dri` is absent. `scripts/run-headless.sh`, `scripts/proof-terminal.sh`, `scripts/proof-input.sh`, `scripts/measure-fps.sh`, `scripts/test-input.sh`, and `scripts/smoke-app.sh` exit if `/dev/dri` exists.
- `gcc-15` and `g++-15` on `PATH`. Override them with `CC` and `CXX`.
- `git`, `wget`, `tar`, `patch`, `python3`, pip, `pkg-config`, `make`, and `ninja`.
- CMake 3.31 or newer. `scripts/build.sh` downloads CMake 3.31.8 into `.build/cmake` when `.build/cmake/bin/cmake` is missing.
- Meson 1.4 or newer. When `meson` is missing or older, the script runs `python3 -m pip install --user --break-system-packages 'meson>=1.7'` and uses `~/.local/bin`.
- Host `foot` for `scripts/proof-terminal.sh` and `scripts/proof-input.sh`. The terminal proof also uses `neofetch`, `lspci` (`pciutils`), and `eglinfo` (`mesa-utils`). `fastfetch` is optional; if it is missing, that pane runs `neofetch --stdout`.

The script builds Wayland 1.25.0 when `wayland-server` is older than 1.25, because wayland-protocols 1.49 marks interfaces `frozen="true"` and wayland-scanner 1.24.0 rejects that attribute. `scripts/pkgconfig/pkg-config` is placed first on `PATH` so this prefix's `-L` flags stay ahead of `/usr`.

## Build, run, and test

`scripts/build.sh` installs into `.build/prefix` (override with `PREFIX`). It does not install under `/usr`. `JOBS` defaults to 2. A clean rebuild deletes `.build` first. The script prints per-stage timings and writes `.build/build-timings.tsv`.

```bash
./scripts/build.sh
./scripts/run-headless.sh
./scripts/run-headless.sh --client
./scripts/test-input.sh
./scripts/measure-fps.sh
```

```bash
rm -rf .build && ./scripts/build.sh
```

`scripts/run-headless.sh` sets `LIBGL_ALWAYS_SOFTWARE=1` and `GALLIUM_DRIVER=llvmpipe`, starts Hyprland with `scripts/headless.lua`, waits for a Wayland socket, and runs `grim -o HEADLESS-1`. With no arguments it writes `proof/hyprland-headless.png`. `--client` builds `clients/shm-window.c` and writes `proof/hyprland-headless-client.png` after `hyprctl clients` lists `shm-window`.

`scripts/test-input.sh` maps `clients/input-sink` and drives it with `clients/vinput.c`. The default text is `KEYBOARD-OK-7741`. Exit 0 means the sink decoded that text and received a left button press. Exit 1 is a compositor, build, or usage failure. Exit 2 means no mapped window before the timeout. Exit 4 means the window mapped and the text never arrived. Exit 5 means the text arrived and no left button did.

`scripts/measure-fps.sh` runs `clients/frame-timer.c` on `HEADLESS-1` and prints interval stats. `--static-ms` defaults to 3000 and `--damage-ms` defaults to 5000.

## Usage

```bash
./scripts/run-headless.sh proof/hyprland-headless.png
./scripts/run-headless.sh --client
./scripts/run-headless.sh --terminal
./scripts/proof-terminal.sh
./scripts/proof-input.sh
./scripts/smoke-app.sh --timeout 20 --class shm-window -- .build/prefix/bin/shm-window
```

`scripts/run-headless.sh --terminal` runs `scripts/proof-terminal.sh`, which writes `proof/hyprland-headless-foot.png`. `scripts/proof-input.sh` writes `proof/hyprland-headless-input.png` after a virtual keyboard types `echo KEYBOARD-OK-7741` and a virtual pointer drag-selects the output. Pass another path as the first argument to either proof script to change the screenshot path.

`scripts/smoke-app.sh` launches one command in the headless session and checks that a mapped window's grim crop is not a flat color. `--timeout`, `--shot`, `--min-variance`, and `--class` match `SMOKE_TIMEOUT` (default 20), `SMOKE_SHOT` (default `.build/smoke-app.png`), `SMOKE_MIN_VARIANCE` (default 25), and a class, initial class, or title substring. Exit 0 means the crop is at or above the variance threshold. Exit 2 means no mapped window before the timeout. Exit 3 means a window mapped and the crop is under the threshold.

The headless output is `1920x1080@60`. There is no pixman renderer and no udmabuf path. The Hyprland build passes `-DNO_XWAYLAND=ON`. `foot` is not built by `scripts/build.sh`. Background is in [docs/PRIOR-ART.md](docs/PRIOR-ART.md) and [docs/FEASIBILITY.md](docs/FEASIBILITY.md).

## Layout

- `patches/aquamarine/0001-shm-allocator-for-headless.patch` and `patches/hyprland/0001-surfaceless-shm-headless.patch` are applied to the cloned pins.
- `scripts/` builds the prefix and runs the headless session.
- `clients/` holds the shm window, frame timer, input sink, and virtual keyboard and pointer client.
- `proof/` holds the tracked screenshots. Other PNG files are gitignored.
- `experiments/` is a small surfaceless EGL probe. See [experiments/README.md](experiments/README.md).

Patches, scripts, docs, and the C clients are BSD 3-Clause. See [LICENSE](LICENSE). `clients/virtual-keyboard-unstable-v1.xml` and `clients/wlr-virtual-pointer-unstable-v1.xml` keep the MIT notices in those files. The vendored pstack skills under `.cursor/` are MIT; see [.cursor/PSTACK-LICENSE](.cursor/PSTACK-LICENSE).
