# Experiments

Small programs run on this VM (x86_64, no `/dev/dri`, no `/dev/udmabuf`, Mesa 25.2.8). They are not part of Hyprland or Aquamarine.

## surfaceless-egl

Creates an `EGL_MESA_platform_surfaceless` display, a surfaceless GLES 3.x context, a 2x2 RGBA8 renderbuffer, and reads one pixel back.

```sh
cc -O2 -Wall -Wextra -o experiments/surfaceless-egl experiments/surfaceless-egl.c -lEGL -lGLESv2
./experiments/surfaceless-egl
```

Needs `libegl1-mesa-dev` and `libgles2-mesa-dev`. The binary is not committed; the source is.
