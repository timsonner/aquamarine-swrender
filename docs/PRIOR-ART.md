# Prior art: CPU-only / no-DRM Hyprland

Research date: 2026-10-10. No upstream issues, pull requests, or comments were opened.

This note covers public history only. The source map and the MVP plan are in [FEASIBILITY.md](FEASIBILITY.md).

## Versions this note is about

| Tree | Tag | Commit |
| --- | --- | --- |
| [hyprwm/Hyprland](https://github.com/hyprwm/Hyprland) | `v0.56.2` | [`efb50993780079460b0cbed1363e2166a2de1d9f`](https://github.com/hyprwm/Hyprland/commit/efb50993780079460b0cbed1363e2166a2de1d9f) |
| [hyprwm/aquamarine](https://github.com/hyprwm/aquamarine) | `v0.15.1` | [`f31c47a1b9d300847d8fc3108ad959448103dfc1`](https://github.com/hyprwm/aquamarine/commit/f31c47a1b9d300847d8fc3108ad959448103dfc1) |
| [wlroots](https://gitlab.freedesktop.org/wlroots/wlroots) | `0.19.1` | [`9b42c1901d967a6a05209de741131053722e9be1`](https://gitlab.freedesktop.org/wlroots/wlroots/-/commit/9b42c1901d967a6a05209de741131053722e9be1) |

Hyprland stopped being a wlroots compositor in 0.42.0. The rewrite is described in [Independent Hyprland](https://hypr.land/news/independentHyprland/): aquamarine is “a tiny library providing an abstraction on top of the very low-level backend stuff” (KMS/DRM, input), and it is explicitly “not a competitor to wlroots.”

## The failure this VM hits

On a machine with no DRM device, Hyprland 0.56.2 asks aquamarine for a mandatory headless backend, an if-available DRM backend, and a fallback Wayland backend (`src/Compositor.cpp` around the `CBackend::create` call; see FEASIBILITY.md). The headless backend starts and returns `drmFD() == -1`. The DRM backend finds no GPU. The Wayland backend has no parent compositor. Aquamarine then refuses to continue:

```
Cannot open backend: no allocator available
CBackend::create() failed!
```

The allocator gate is a GBM allocator created only when some backend returns `drmFD() >= 0`. The comment above that loop, in aquamarine 0.15.1 `src/backend/Backend.cpp`, is:

> TODO: obviously change this when (if) we add different allocators.

The null backend is the only implementation allowed to finish `start()` with no allocator. It cannot create outputs.

A third-party container image documents the same gate in the same words: [cloudsnacks/containers PR #1](https://github.com/cloudsnacks/containers/pull/1) (Arch/Hyprland streaming desktop). Their `start-desktop` checks for `/dev/dri/renderD128` and exits before the opaque allocator error. They state that `CHeadlessBackend::drmFD()` returns `-1` and that the image cannot start without `/dev/dri`.

## Maintainer stance

There is no public “we will never render on the CPU” policy, and there is also no CPU-only backend. The record is that software GL is an accidental fallback when a DRM node exists and has no real GL driver, and that VMs and headless GPUs are tolerated only insofar as they still look like DRM devices.

### wlroots era (through 0.41)

Vaxry (GitHub `vaxerski`) treated software rendering as an opt-in wlroots escape hatch.

[Hyprland #797](https://github.com/hyprwm/Hyprland/issues/797) (2022-10-06), VMware guest, closed by him:

> you need to enable software rendering with `WLR_RENDERER_ALLOW_SOFTWARE=1` because obviously a vm doesn't have a gpu

Same thread, later the same day:

> try not using a VM.

[Hyprland #1056](https://github.com/hyprwm/Hyprland/issues/1056) (NixOS QEMU, closed 2023-11-05):

> provide the log from `WLR_RENDERER_ALLOW_SOFTWARE=1 HYPRLAND_LOG_WLR=1 Hyprland` (/tmp/hypr/)

and, closing it:

> this is not an issue with hl but with the vm. Make sure to allow software rendering. Anything else, your issue.

[hyprwm/hyprland-wiki #245](https://github.com/hyprwm/hyprland-wiki/issues/245) (2023-06-09):

> I don't think hardware rendering can be disabled without the `WLR_RENDERER_ALLOW_SOFTWARE` env var set.

[Hyprland #6053](https://github.com/hyprwm/Hyprland/issues/6053) (Hyper-V `hyperv_drm`, wlroots-era 0.39):

> I don't think it's up to us to support but rather wlroots.
>
> At any rate, what's the point?

and later:

> generally if sway works it could be an issue within hyprland, but I have no experience with hyper-v and little interest in supporting *windows vms*

The reporter on that issue said enabling `WLR_RENDERER_ALLOW_SOFTWARE` “was very unpleasant.” A community comment on #797 reported that `WLR_NO_HARDWARE_CURSORS=1` was also required in VMware. That variable is a wlroots variable. It does nothing to aquamarine.

`WLR_RENDERER_ALLOW_SOFTWARE` still exists in wlroots 0.19.1 (`render/egl.c`): a device advertising `EGL_MESA_device_software` is rejected unless the variable is set or the caller passed `allow_software`. Hyprland 0.56.2 does not read that variable. The GLES renderer is Hyprland’s own code, and it no longer goes through `wlr_egl`.

### After aquamarine

Headless outputs exist, and they still assume a GBM allocator from some other backend’s DRM fd.

[aquamarine #206](https://github.com/hyprwm/aquamarine/issues/206) (headless outputs ignore the FPS cap; closed by vaxerski, 2026-03). The thread is about a headless monitor beside real outputs (VNC / Sunshine). A commenter suggested a dummy plug. Nobody there is running without `/dev/dri`.

[aquamarine #209](https://github.com/hyprwm/aquamarine/pull/209) (merged 2025-09-19, author vaxerski), the null backend:

> Adds a null backend. A null backend doesn't do anything, but allows us to use e.g. the GBM allocator and swapchains by manually passing a drm fd
>
> Required by hyprtoolkit

That is the closest thing to a “backend with no outputs,” and it still wants a caller-supplied DRM fd and the GBM allocator.

[aquamarine #255](https://github.com/hyprwm/aquamarine/pull/255) (merged 2026-05-15, `AQ_NO_KMS_REQUIREMENT`). Lets a render-only DRM node through `CSessionDevice::openIfKMS`. vaxerski’s merge comment is “oops forgor to merge.” The variable is in aquamarine 0.15.1 `src/backend/Session.cpp` and is absent from that tag’s `docs/env.md`. It does not help a machine with no `/dev/dri` at all: there is still no node to open.

[Hyprland #13616](https://github.com/hyprwm/Hyprland/pull/13616) (open as of 2026-10-10, “Add support for headless GPU”). Creates an initial `HEADLESS-0` when the session’s cards have no KMS connector, for SR-IOV / vGPU guests that have a render node and no connector. vaxerski, 2026-05-16:

> tag me once the aq mr is in a release

and 2026-05-30:

> aq landed, but I'd wait for https://github.com/hyprwm/Hyprland/pull/14547 to be sure there won't be some funny interactions between the two

#14547 later merged. #13616 is still open. The comments are about sequencing, and the feature is a render-node GPU with no connector. Hyprland 0.56.2 does not contain this patch. Its fallback output is named `FALLBACK`, created by `CFallbackStateKeeper` after a 2 second timeout with no monitors, and that path is never reached if `CBackend::start()` has already aborted.

[Hyprland #16343](https://github.com/hyprwm/Hyprland/pull/16343) (merged 2026-09-27, merge commit `4bb6844b0351e4fbf2e3d4e46ae71b551a0e0a42`). “render: detect software rendering from the GL renderer.” The author (scottjones) explains that on an M3 with `simpledrm` and no GPU acceleration, `isSoftware()` never tripped because it compared DRM driver names (`simpledrm`) against the strings `llvmpipe` / `softpipe` / `Software Rasterizer`. The existing `glFinish` fallback then never ran, and frames tore. vaxerski reviewed the helper, then approved with:

> thanks!

This patch is **not** in the `v0.56.2` tag. It is the current maintainer position on software GL: when the process is already on llvmpipe, detect it from `GL_RENDERER` and take the sync fallback. It does not remove the GBM allocator requirement. `simpledrm` is still a DRM device.

[Hyprland discussion #12839](https://github.com/hyprwm/Hyprland/discussions/12839) (vaxerski, 2026-01-04):

> hyprland runs exclusively on one gpu. If you are running it on nv, it won't use intel. It might happen if a display is only reachable from the other gpu (it then does a copy and passes to KMS) but I guess this is not the case here

### The one public “no real GPU” Hyprland report

[aquamarine #351](https://github.com/hyprwm/aquamarine/issues/351) (open, filed 2026-08-06, zero comments). Hyprland 0.56.0, aquamarine 0.13.0, Mesa 26.1.5, renderer `llvmpipe (LLVM 22.1.8, 256 bits)`, Hyper-V guest:

- KMS-only `hyperv_drm` at `/dev/dri/card1` (no paired `renderD*`)
- a render node manufactured with `modprobe vgem` (`/dev/dri/renderD128`)
- the physical `Virtual-1` connector disabled
- a single headless output

Frames delivered to `zwlr_screencopy_v1` and `ext_image_copy_capture_v1` sat around 3–13 fps with low CPU. The reporter suspected Hyprland’s render/commit path, not aquamarine’s timer. No maintainer has answered.

That setup is the community workaround, and it is unavailable here: this VM has no `/dev/dri`, and the kernel cannot load `vgem` or `vkms`.

### Discord and Matrix

Public web search does not turn up an archived Discord or Matrix transcript with a software-rendering policy quote. Vaxry points development questions at Discord `#hyprland-dev` and Matrix `#[email protected]` in [Come help shape Hyprland](https://blog.vaxry.net/articles/2024-shapeHyprland) (the Matrix room name is obfuscated on the blog). His GitHub profile lists Matrix `@vaxry:matrix.vaxry.net`. Those rooms are not publicly logged in a form this search could quote. Everything above is from GitHub, the wiki, and hypr.land.

## Wiki

[Virtual GPU](https://wiki.hypr.land/configuring/extra/virtual-gpu/) (page fetched 2026-10-10, “latest git”):

- Virtio-GPU “provides an emulated screen output. Therefore you can use Hyprland normally with it, with no extra effort required.” Virtio-GPU is a DRM device.
- Render-only vGPUs need `AQ_NO_KMS_REQUIREMENT=1`. They still have a render node under `/dev/dri`.
- “When Hyprland starts without any display output, it will initialize a headless output called `HEADLESS-0`.” That sentence describes the unreleased #13616 behavior. Tag 0.56.2 names the timeout fallback `FALLBACK` and only creates it after the backend has already started.
- Remote access is “a remote desktop server, supporting the wlroots capture protocol” (Sunshine, wayvnc). That is `zwlr_screencopy_v1` / the image-copy protocol, which Hyprland implements itself.

The wiki never describes a machine with no DRM node.

## What Hyprland’s own CI does

CI does not run Hyprland on the CPU.

- `.github/workflows/ci.yaml` on tag 0.56.2 builds Hyprland in an Arch container (`make nopch`). It does not execute the compositor.
- `.github/workflows/nix-test.yml` builds `checks.x86_64-linux.tests`.
- `nix/tests/default.nix` runs a NixOS VM test (`hyprland_gtests` and `hyprtester`) with:

```nix
qemu.options = [ "-vga none -device virtio-gpu-pci" ];
```

That is a virtio DRM/GPU device. `AQ_TRACE` and `HYPRLAND_TRACE` are set. There is no `WLR_RENDERER`, no llvmpipe force, and no headless-only node.

Aquamarine’s `.github/workflows/nix.yml` on tag 0.15.1 only `nix build`s the library. The `aquamarine-with-tests` matrix entry is commented out. Those tests are DRM/session tests (`tests/SimpleWindow.cpp` and friends), not a no-GPU compositor run.

So: Hyprland’s integration test already boots a VM, and that VM is given a virtio GPU. Nothing in-tree runs the compositor with an empty `/dev/dri`.

## wlroots reference (0.19.1)

Sway and Cage headless work because wlroots splits “who allocates the output buffer” from “who composites,” and the headless backend accepts CPU memory.

`backend/headless/backend.c` sets:

```c
backend->backend.buffer_caps =
    WLR_BUFFER_CAP_DATA_PTR | WLR_BUFFER_CAP_DMABUF | WLR_BUFFER_CAP_SHM;
```

`wlr_backend_get_drm_fd` on a pure headless backend is negative. `wlr_renderer_autocreate` (`render/wlr_renderer.c`) tries GLES2, then Vulkan, both of which call `open_preferred_drm_fd` and give up with “no DRM FD available.” It then creates the pixman renderer when `!has_render_node(backend)` (or when `WLR_RENDERER=pixman`). `wlr_pixman_renderer_create` (`render/pixman/renderer.c`) registers `WLR_BUFFER_CAP_DATA_PTR` only. Pixman composites with `pixman_image_composite32` straight into the buffer’s `begin_data_ptr_access` mapping. There is no EGL display.

`wlr_allocator_autocreate` (`render/allocator/allocator.c`) then:

1. Tries GBM only when both sides advertise `WLR_BUFFER_CAP_DMABUF` and `drm_fd >= 0`.
2. Tries the shm allocator when the capability masks overlap `SHM | DATA_PTR`. Pixman has `DATA_PTR`, headless has both, so this succeeds. `render/allocator/shm.c` `allocate_shm_file`s (POSIX shm, then `mmap`) and exposes `get_shm` plus a data pointer. No DRM fd.
3. Tries DRM dumb buffers only when `drm_fd >= 0` and `drmIsMaster`.
4. Tries udmabuf only when `drm_fd < 0` and both sides want `DMABUF | SHM`. Pixman does not advertise `SHM`, so a headless+pixman compositor does not need `/dev/udmabuf`. The udmabuf allocator (`render/allocator/udmabuf.c`) `open`s `/dev/udmabuf` and `ioctl`s `UDMABUF_CREATE` on a sealed memfd so a GLES renderer can import the same memory as a dmabuf.

Headless commit (`backend/headless/output.c`) does not scan out. It emits a present event and arms a frame timer. The pixels stay in the shm buffer for screencopy to read.

That is the shape aquamarine does not have: an allocator that can be created with no DRM fd, and a renderer that can target `BUFFER_CAPABILITY_DATAPTR`.

## Search log

GitHub issue search (API, 2026-10-10), plus web search over the wiki, hypr.land, and the two repos:

| Query | What came back |
| --- | --- |
| `repo:hyprwm/Hyprland "no allocator available"` | Startup crashes where GBM failed on a real or broken GPU (#11533, #9492, #7791), and the string inside unrelated diffs. No “add an shm allocator” issue. |
| `repo:hyprwm/aquamarine "no allocator available"` | [#409](https://github.com/hyprwm/aquamarine/issues/409) (open): a transient libseat `EBUSY` is logged as “not a KMS device” and then becomes fatal with the same critical line. Still a machine that has DRM nodes. |
| `repo:hyprwm/Hyprland "software rendering"` | #16343 above; many cursor/VRR hits that mention the “software renders/cursors” direct-scanout block reason; old VM threads #797 and #1056. |
| `repo:hyprwm/Hyprland llvmpipe` | Client or VM performance bugs. #6967 is “m_pAqBackend couldn't start” on a GPU machine, not a design discussion. |
| `repo:hyprwm/aquamarine headless` | #351 above; #206 FPS cap; headless bugs that assume a DRM session exists (#348, #343). |
| `repo:hyprwm/aquamarine "allocator" is:pr` | GBM, dumb, multi-GPU, linear blit. [#31](https://github.com/hyprwm/aquamarine/pull/31) / [#104](https://github.com/hyprwm/aquamarine/pull/104) added the DRM dumb allocator (needs a primary node and `DRM_CAP_DUMB_BUFFER`). No shm allocator PR. |
| `repo:hyprwm/Hyprland "headless" is:pr` | #13616 above; #15775 hides the `FALLBACK` placeholder from output-management; other hits are the word “headless” in unrelated patches. |
| Web: pixman / llvmpipe / “no allocator” | The cloudsnacks note, the wiki vGPU page, and wlroots’ pixman renderer docs. No aquamarine pixman renderer. |

Discussions that show the same log line with a GPU present, and are not design discussions: [Hyprland #10737](https://github.com/hyprwm/Hyprland/discussions/10737), [Hyprland #12295](https://github.com/hyprwm/Hyprland/discussions/12295), [nix-community/home-manager #9337](https://github.com/nix-community/home-manager/issues/9337). On NixOS the usual fix is `hardware.graphics.enable` / `programs.hyprland.enable` so a DRM render node exists. A maintainer-side reply on the home-manager thread: “It's always worked like this. Hyprland can't start unless the graphics driver is enabled.”

[aquamarine #290](https://github.com/hyprwm/aquamarine/issues/290) is the Asahi case people mean by “software rendering”: the KMS node and the render node have different parents, the renderer is attached to the KMS fd, and Mesa falls back to llvmpipe. The proposed fix is “pick the only `renderD*` node,” i.e. get off llvmpipe. Same theme in [Hyprland #6340](https://github.com/hyprwm/Hyprland/issues/6340) from the wlroots era (`Software rendering detected, please use the WLR_RENDERER_ALLOW_SOFTWARE environment variable`).
