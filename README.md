# CPU-only Hyprland notes

Notes on running Hyprland 0.56.2 / Aquamarine 0.15.1 with no DRM device and no GPU. This repository is the research record for that question. It does not vendor Hyprland.

- [docs/PRIOR-ART.md](docs/PRIOR-ART.md) — issues, maintainer comments, CI, and how wlroots headless + pixman does it.
- [docs/FEASIBILITY.md](docs/FEASIBILITY.md) — GBM/DRM dependency map, surfaceless EGL results from this VM, MVP patch plan, go recommendation.
- [experiments/](experiments/) — a small surfaceless EGL + GLES probe. Build instructions are in [experiments/README.md](experiments/README.md).

Stages 1 and 2 only. The compositor patch is a later follow-up.
