# Feasibility: headless Hyprland with no DRM device

Research date: 2026-10-10. Sources were cloned and read at these commits. No upstream issues or pull requests were opened. No kernel modules were loaded.

| Tree | Tag | Commit |
| --- | --- | --- |
| Hyprland | `v0.56.2` | `efb50993780079460b0cbed1363e2166a2de1d9f` |
| Aquamarine | `v0.15.1` | `f31c47a1b9d300847d8fc3108ad959448103dfc1` |
| wlroots (reference only) | `0.19.1` | `9b42c1901d967a6a05209de741131053722e9be1` |

The VM this was checked on: Ubuntu 24.04, x86_64, kernel `6.12.94+`, no `/dev/dri`, no `/dev/udmabuf`, Mesa `25.2.8-0ubuntu0.24.04.4` (llvmpipe, LLVM 20.1.2). Prior art and maintainer quotes are in [PRIOR-ART.md](PRIOR-ART.md).

## Verdict

**Go**, for a narrow MVP: one headless output, no `/dev/dri`, a GLES 3.2 context on llvmpipe through `EGL_MESA_platform_surfaceless`, and a screenshot through the existing `zwlr_screencopy_v1` shm path (`grim`).

The work is a small allocator plus a different EGL display and a render target that is a GL renderbuffer. It is a localized patch in two libraries. The expensive part is the sweep of “DRM fd is always valid” assumptions, and building both trees, which this stage does not do.

Three approaches, separately:

| Approach | Verdict |
| --- | --- |
| (a) shm/memfd allocator in aquamarine, modeled on wlroots `wlr_shm_allocator` | Required piece of the MVP. The buffer types already exist. The backend refuses to start without an allocator, and every current allocator needs a DRM fd. |
| (b) Keep Hyprland’s GLES renderer; run it on llvmpipe via surfaceless EGL (or the Mesa software EGL device); render into a GL renderbuffer; `glReadPixels` for shm clients | This is the MVP renderer. Proven on this VM: GLES 3.2, `GL_RENDERER` = llvmpipe, RGBA8 FBO, readback of a known color. `EGL_PLATFORM_DEVICE_EXT` against the `EGL_MESA_device_software` device works the same way. |
| (c) A pixman renderer inside Hyprland, or nesting under Sway/Cage/Weston, or udmabuf so the existing EGLImage path can stay | Leave these out of the MVP. Pixman means a second renderer under a GLES-shaped scene graph. Nesting dies because the Wayland backend requires `zwp_linux_dmabuf_v1`. udmabuf needs `/dev/udmabuf`, which this VM does not have. |

## GBM / DRM dependency map

Line numbers are the tagged trees above.

### Where startup dies

Hyprland always requests headless as mandatory, DRM as if-available, Wayland as fallback:

- `Hyprland/src/Compositor.cpp:311-319` builds that list.
- `Hyprland/src/Compositor.cpp:321` calls `CBackend::create`.
- `Hyprland/src/Compositor.cpp:335-340` aborts with `CBackend::create() failed!` if `start()` returns false.
- `Hyprland/src/Compositor.cpp:355-359` then stores `m_aqBackend->drmFD()` and `drmRenderNodeFD()`. Both are `-1` in the no-DRM case, and the process has already exited.

Aquamarine `CBackend::start`:

- `aquamarine/src/backend/Backend.cpp:162-174`. Comment on line 162: “TODO: obviously change this when (if) we add different allocators.” The loop calls `CGBMAllocator::create` on the first implementation with `drmFD() >= 0`.
- `aquamarine/src/backend/Backend.cpp:176-178`. If that produced nothing, and the first implementation is not the null backend, log `Cannot open backend: no allocator available` and return false.
- `aquamarine/src/backend/Backend.cpp:220-228` and `:231-239`. `CBackend::drmFD()` / `drmRenderNodeFD()` walk implementations and return `-1` when every one does.

Headless:

- `aquamarine/src/backend/Headless.cpp:133-138`. `drmFD()` and `drmRenderNodeFD()` return `-1`.
- `aquamarine/src/backend/Headless.cpp:157-181`. `getRenderFormats()` copies the DRM backend’s formats when one exists, otherwise a hardcoded 8-bit and 10-bit list with `DRM_FORMAT_INVALID` / `DRM_FORMAT_MOD_LINEAR`.
- `aquamarine/src/backend/Headless.cpp:203`. `createOutput` builds the swapchain with `backend->primaryAllocator`.
- `aquamarine/src/backend/Headless.cpp:27-33`. `commit()` snapshots state, emits `commit` and a successful `present`, and does not look at the buffer.
- `aquamarine/src/backend/Headless.cpp:149-150`. `setCursor` returns false.
- `aquamarine/src/backend/Headless.cpp:251-257`. `preferredAllocator` / `getAllocators` return `backend->primaryAllocator` only.

DRM, the only place an allocator is born today:

- `aquamarine/src/backend/drm/DRM.cpp:295-301`. `CDRMBackend::attempt` opens a libseat session even before it knows a GPU exists. If the seat opens and `scanGPUs` is empty, `backend->session` stays set and `hasSession()` is true with zero devices.
- `aquamarine/src/backend/drm/DRM.cpp:327-329`. `drm: Found no gpus to use, cannot continue`.
- `aquamarine/src/backend/drm/DRM.cpp:287`. On a real GPU, `CDRMDumbAllocator::create(gpu->fd)` runs beside GBM. Dumb buffers are a cursor/scanout fallback, and they still need DRM.
- `aquamarine/src/allocator/DRMDumb.cpp:113-116`. Dumb allocator refuses a non-primary node.
- `aquamarine/src/allocator/DRMDumb.cpp:51`. `drmPrimeHandleToFD` exports a dmabuf. `type()` is `BUFFER_TYPE_DMABUF` (`DRMDumb.cpp:81-82`) even though `beginDataPtr` also works (`:101-103`) and `isSynchronous()` is true (`:89-90`).
- `aquamarine/src/allocator/GBM.cpp:331-336`. GBM create requires `DRM_CAP_PRIME` export.
- `aquamarine/src/allocator/GBM.cpp:340-342`. Failure here is `Cannot create a GBM Allocator: gbm failed to create a device.`
- `aquamarine/src/allocator/GBM.cpp:352`. `gbm_create_device(fd)`.
- `aquamarine/src/allocator/GBM.cpp:274-283`. GBM buffers are `BUFFER_TYPE_DMABUF`, capability none, `isSynchronous()` false.

Null backend (`aquamarine/src/backend/Null.cpp:33-38`, `:75-77`): `drmFD()` is `-1`, `createOutput` returns false. `Backend.cpp:176` special-cases it so hyprtoolkit can pass a DRM fd in from outside (`aquamarine` PR #209).

Wayland backend, which is why nesting fails:

- `aquamarine/src/backend/Wayland.cpp:133-149`. Startup binds `zwp_linux_dmabuf_v1` version 4 and returns false when it is missing, when `initDmabuf()` fails, or when `wl_shm` is missing. Cage, Weston, and Sway on the pixman renderer do not advertise `zwp_linux_dmabuf_v1`, so this backend never starts under them.
- `aquamarine/src/backend/Wayland.cpp:159-165`. `drmFD()` is the node opened from the parent’s dmabuf feedback main device. A parent with no DRM device yields no fd, and the same GBM gate fires even if the protocol had been optional.

Allocator interface, already shm-shaped:

- `aquamarine/include/aquamarine/allocator/Allocator.hpp:17-19`. `eAllocatorType` is `AQ_ALLOCATOR_TYPE_GBM` and `AQ_ALLOCATOR_TYPE_DRM_DUMB` only.
- `aquamarine/include/aquamarine/buffer/Buffer.hpp:15-18`. `eBufferType` already has `BUFFER_TYPE_SHM`.
- `aquamarine/include/aquamarine/buffer/Buffer.hpp:33-40`. `SSHMAttrs` is fd, format, size, stride, offset.
- `aquamarine/include/aquamarine/buffer/Buffer.hpp:10-13`. `BUFFER_CAPABILITY_DATAPTR`.
- `aquamarine/src/buffer/Buffer.cpp:6-16`. Default `dmabuf()`, `shm()`, and `beginDataPtr()` fail. A new buffer type opts in by overriding them.

Swapchain assumes dmabuf metadata:

- `aquamarine/src/allocator/Swapchain.cpp:17-19`. A null allocator makes a swapchain that cannot reconfigure.
- `aquamarine/src/allocator/Swapchain.cpp:54-55`. After allocate, if the requested format was `DRM_FORMAT_INVALID`, the stored format is `buffers[0]->dmabuf().format`. An shm buffer whose `dmabuf()` stays at the default would record format 0.
- `aquamarine/src/allocator/Swapchain.cpp:79-88`. Acquire logs `dmabuf().format` and `dmabuf().modifier` unconditionally.
- `aquamarine/src/allocator/Swapchain.cpp:62-71`. `next()` returns null when the allocator is missing or length is 0. It does not itself require GBM.

### Where Hyprland binds the output buffer to a dmabuf

Normal frames:

- `Hyprland/src/render/Renderer.cpp:1765-1778`. `beginRender` does `swapchain->next()` and `initRenderBuffer(buffer, drmFormat)`.
- `Hyprland/src/render/GLRenderer.cpp:50-58`. `initRenderBuffer` calls `getOrCreateRenderbuffer`.
- `Hyprland/src/render/gl/GLRenderbuffer.cpp:34-65`. The renderbuffer is an EGL image from `buffer->dmabuf()`, imported with `glEGLImageTargetRenderbufferStorageOES`. `dmabuf().success == false` fails the frame. There is no shm branch.
- `Hyprland/src/render/GLRenderer.cpp:108-109`. On a normal frame, `endRender` does `state->setBuffer(m_currentBuffer)`. Headless `commit()` ignores the pixels. The EGL image exists so the GL commands have a target, which on a DRM backend is also the scanout buffer.

Screenshot / screencopy frames already avoid that import:

- `Hyprland/src/protocols/Screencopy.cpp:76-94`. `zwlr_screencopy_frame_v1` sends an shm buffer (`sendBuffer`) and, at version ≥ 3, also a dmabuf format hint (`sendLinuxDmabuf`).
- `Hyprland/src/managers/screenshare/ScreenshareFrame.cpp:163-166`. shm buffers go to `copyShm()`, dmabufs to `copyDmabuf()`.
- `Hyprland/src/managers/screenshare/ScreenshareFrame.cpp:440-462`. `copyShm` allocates an offscreen `CGLFramebuffer`, renders with `beginFullFakeRender` (`RENDER_MODE_FULL_FAKE`), and `readPixels` into the client shm.
- `Hyprland/src/render/GLRenderer.cpp:105-106`. `RENDER_MODE_FULL_FAKE` returns before `setBuffer`. It never touches the output swapchain.
- `Hyprland/src/render/gl/GLFramebuffer.cpp:15-36`. That offscreen FB is `glTexImage2D`, not an imported dmabuf.
- `Hyprland/src/render/gl/GLFramebuffer.cpp:136-244`. `readPixels` requires `buffer->shm().success`, then `glReadPixels`. The comment on line 229 says clients should prefer a dma buffer. The shm path is the one `grim` uses.
- `Hyprland/src/protocols/ImageCopyCapture.cpp:37-39` and `:395`. `ext_image_copy_capture_v1` is the same screenshare session, so the same shm readback applies.

`hyprctl` in 0.56.2 has no screenshot command. `Hyprland/src/debug/HyprCtl.cpp:1777-1786` can `output create headless <name>`, which calls `CHeadlessBackend::createOutput`. That only works after the backend has started, which is the thing that fails today. The MVP proof is `grim` (or any `zwlr_screencopy_v1` shm client), not `hyprctl screenshot`.

Client buffers are already split:

- `Hyprland/src/render/Renderer.cpp:905-922`. `createTexture(IBuffer)` uses `dmabuf()` and, on failure, `shm()` plus `beginDataPtr`, then uploads pixels. `Hyprland/src/protocols/core/Shm.cpp:46-62` is the client wl_shm buffer. A CPU client that only speaks `wl_shm` already has an upload path, once a GL context exists.

### EGL display creation

`Hyprland/src/render/OpenGL.cpp`, `CHyprOpenGLImpl::CHyprOpenGLImpl` (line 289). The DRM fd is `m_drmRenderNode.fd` if `>= 0`, else `m_drm.fd`.

- Lines 309-311. Hard `RASSERT` that `eglGetProcAddress` returns non-null for `eglCreateSyncKHR`, `eglDupNativeFenceFDANDROID`, and `eglWaitSyncKHR`. On this VM those pointers are non-null. The assert would pass.
- Lines 333-340. If the client extension string contains `EXT_platform_device`, call `eglDeviceFromDRMFD` and `initEGL(false)` (`EGL_PLATFORM_DEVICE_EXT`).
- `eglDeviceFromDRMFD` (lines 246-286) matches `EGL_DRM_DEVICE_FILE_EXT` against `drmGetDevice(drmFD)`. With fd `-1`, `drmGetDevice` fails and this returns `EGL_NO_DEVICE_EXT`. The Mesa software device that does enumerate has a null DRM file, so the matcher would skip it even if it were queried without a fd.
- Lines 342-355. Fallback is `EGL_PLATFORM_GBM_KHR` via `gbm_create_device` on a reopened render node. No render node, so `Couldn't open a gbm fd`.
- Line 358. If both fail: `EGL does not support KHR_platform_gbm or EXT_platform_device`.
- Line 373. `RASSERT` on `GL_EXT_texture_format_BGRA8888`. llvmpipe on this VM has it.
- `initEGL` (lines 152-161) takes only GBM or device. `EGL_PLATFORM_SURFACELESS_MESA` is never requested.
- Lines 515-523. `initDRMFormats` returns early when `EGL_EXT_image_dma_buf_import` is missing. On this VM the surfaceless display **does** advertise that extension, and `eglQueryDmaBufFormatsEXT` returned 69 formats. Hyprland would fill `m_drmFormats` even with no DRM node. Advertising those formats to clients still depends on the protocol globals below.
- Lines 384-388 and `explicitSyncSupported()` at line 2646. Explicit sync is on only when the display extension string contains `EGL_ANDROID_native_fence_sync`. This VM’s surfaceless display does not advertise it, and `eglCreateSyncKHR(EGL_SYNC_NATIVE_FENCE_ANDROID)` returns `EGL_BAD_ATTRIBUTE` (`0x3004`). `CEGLSync::create` (line 2737) `RASSERT`s the extension before calling the sync. Callers that honor `explicitSyncSupported()` stay on the `glFlush` / `glFinish` path (`GLRenderer.cpp:111-115`).

Software detection in 0.56.2 does not look at `GL_RENDERER`:

- `Hyprland/src/render/Renderer.cpp:93-138`. `m_software` is set only when `drmGetVersion`’s name contains `llvmpipe`, `softpipe`, or `Software Rasterizer`. No DRM fd means `drmGetVersion` fails, the log line is “No primary DRM driver information found”, and `m_software` stays false.
- `Hyprland/src/render/GLRenderer.cpp:114-115`. The `glFinish` fallback runs only when `isSoftware()` (or the NVIDIA antiflicker flag). On llvmpipe, `glFlush` alone drops frames. That is the bug #16343 fixed on `main` after 0.56.2, by reading `GL_RENDERER` with the context current. The MVP should set the flag from `GL_RENDERER` the same way. Cherry-picking the whole PR is optional; the detection is the part that matters.

### Dmabuf feedback and the other DRM protocols

These already disable themselves when there is no device. The MVP should leave that behavior alone.

- `Hyprland/src/protocols/LinuxDMABUF.cpp:443-451`. On compositor ready, `devIDFromFD(rendererFD)` failure logs `failed to get drm dev, disabling linux dmabuf` and `removeGlobal()`. `zwp_linux_dmabuf_v1` goes away. Per-monitor scanout tranches are only built when `hasSession()` (line 464).
- `Hyprland/src/protocols/MesaDRM.cpp:115-123`. `wl_drm` is removed when `drmGetDevice2(drmFD)` fails.
- `Hyprland/src/protocols/DRMSyncobj.cpp:204-207` and `Hyprland/src/Compositor.cpp:361-378`. Explicit timeline syncobj is off when both fds are negative. `syncObjSupport` returns false for `fd < 0` (`Compositor.cpp:363-364`).
- `Hyprland/src/Compositor.cpp:173`. `supportsDrmSyncobjTimeline()` is the OR of those two flags.

`wl_shm` is independent of DRM (`Hyprland/src/protocols/core/Shm.cpp`). It always advertises at least `ARGB8888` and `XRGB8888`.

### What a missing dmabuf global breaks

Clients that can allocate `wl_shm` keep working, because the compositor already uploads those buffers (`Renderer.cpp:912-922`) and screencopy already reads back into them.

What loses a path:

- Direct scanout and hardware planes. Headless commit never scans out. Irrelevant to the MVP.
- `zwp_linux_dmabuf_v1` and dmabuf feedback. Clients that refuse `wl_shm` (some mpv `dmabuf-wayland` builds, some games, Firefox WebRender when it will not fall back) get no buffer path. GTK, Qt, and `grim` speak shm.
- `wl_drm` (legacy Mesa). Same class of client.
- `wp_linux_drm_syncobj_v1`. Clients fall back to implicit sync. On llvmpipe that fallback must be `glFinish`, which depends on `m_software`.
- Screencopy’s dmabuf hint (`Screencopy.cpp:91-92` still sends `sendLinuxDmabuf` when the format is valid). A client that prefers the dmabuf hint and then finds no `zwp_linux_dmabuf_v1` global must use the shm buffer the same frame event already described. `grim` does that. A client that only copies into dmabufs will fail.
- Xwayland’s glamor/DRI3 path wants a render node. The MVP can leave Xwayland off (`HYPRLAND`’s no-xwayland build, or simply not starting it). An X11 client is outside the proof.
- Hardware cursors. `CHeadlessBackend::setCursor` returns false, and the software-cursor path already exists (`PointerManager.cpp` around the `hardwareFailed` check).
- Multi-GPU copies, EGL device matching by render-node path, and `AQ_DRM_DEVICES`. Nothing to select.

`ecosystem:enforce_permissions` defaults to false (`Hyprland/src/config/values/ConfigValues.cpp:620`), and `clientPermissionMode` returns allow in that case (`DynamicPermissionManager.cpp:80-83`). A default config does not pop a screencopy permission dialog. Turning the option on without a seat to click “allow” would stall `grim` in `PERMISSION_RULE_ALLOW_MODE_PENDING` (`ScreenshareFrame.cpp:154-160`).

Input is a session feature. `CDRMBackend::attempt` is what calls `CSession::attempt` (`DRM.cpp:295-297`). With no GPU the DRM implementation is dropped, but a seat that opened successfully stays on `backend->session`. Libinput is created inside that session (`Session.cpp:345`). On this VM a seat may fail to open (no logind session, no devices). The screenshot MVP does not need a pointer. A keyboard is a follow-up, not a blocker for `grim` of a single output.

The fallback output in 0.56.2 is `FALLBACK`, created 2000 ms after ready if no monitor exists (`Hyprland/src/state/FallbackState.hpp:8`, `FallbackState.cpp:13` and `:100-115`). That is enough “one output” once `start()` succeeds. Creating it immediately when `drmFD() < 0` makes the proof deterministic. The wiki’s `HEADLESS-0` name belongs to unreleased #13616.

## (a) What an shm allocator has to be

Mirror `CDRMDumbAllocator` / `CDRMDumbBuffer` and wlroots `render/allocator/shm.c`, without a DRM fd.

- New `eAllocatorType::AQ_ALLOCATOR_TYPE_SHM`.
- `CSHMAllocator::create(backend)` uses `memfd_create` (or POSIX shm, as wlroots does in `util/shm.c:39`) plus `ftruncate` and `mmap`. No `drmGetCap`, no prime, no `/dev/udmabuf`.
- Buffer: `type() == BUFFER_TYPE_SHM`, `caps()` includes `BUFFER_CAPABILITY_DATAPTR`, `isSynchronous() == true`, `good()` when the mapping exists.
- `shm()` fills `SSHMAttrs` (fd, `DRM_FORMAT_XRGB8888` or `ARGB8888`, size, stride aligned to 4 bytes, offset 0). `dmabuf()` stays the failing default so nothing tries to import it as an EGL image by accident.
- `beginDataPtr` / `endDataPtr` return the mapping. `drmFD()` returns `-1`.
- `CBackend::start`: when the GBM loop finds no fd, set `primaryAllocator` to the shm allocator instead of logging the critical error. Keep the null-backend exception as it is.
- `CSwapchain::fullReconfigure` and the format fallback at `Swapchain.cpp:55` must read `shm().format` when `dmabuf().success` is false, or the swapchain records format 0 and the renderer is asked for `DRM_FORMAT_INVALID`.
- Headless `createOutput` already passes `primaryAllocator` into the swapchain. No headless change beyond that, once the primary allocator exists.
- Formats: headless `getRenderFormats()` already lists `XRGB8888` / `ARGB8888`. The allocator should accept those and reject the 10-bit modifiers it cannot store. One format is enough for the MVP.

wlroots’ dumb allocator is the wrong template for this VM. It needs a primary node and `DRM_CAP_DUMB_BUFFER` (`DRMDumb.cpp:113-127`). udmabuf is the wrong template too: `wlr_udmabuf_allocator_create` opens `/dev/udmabuf` (`wlroots/render/allocator/udmabuf.c:144-148`), and this kernel does not have that device node.

## (b) Surfaceless GLES on this VM

`experiments/surfaceless-egl.c` was built against `libegl1-mesa-dev` / `libgles2-mesa-dev` (Mesa 25.2.8) and run with no `/dev/dri`. Result: **pass**.

Client extensions include `EGL_MESA_platform_surfaceless`, `EGL_EXT_platform_device`, and `EGL_KHR_platform_gbm`. `eglQueryDevicesEXT` returns one device, extensions `EGL_MESA_device_software EGL_EXT_device_drm_render_node`, DRM file null.

Surfaceless display (`eglGetPlatformDisplayEXT(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, NULL)`):

- EGL 1.5, vendor Mesa Project
- Display extensions include `EGL_KHR_surfaceless_context`, `EGL_KHR_no_config_context`, `EGL_EXT_image_dma_buf_import`, `EGL_EXT_image_dma_buf_import_modifiers`, `EGL_KHR_fence_sync`, `EGL_KHR_wait_sync`
- Display extensions do **not** include `EGL_ANDROID_native_fence_sync` or `EGL_KHR_platform_gbm`
- `eglCreateContext` GLES 3.2 with `EGL_NO_CONFIG_KHR` succeeded
- `eglMakeCurrent(EGL_NO_SURFACE, EGL_NO_SURFACE, ctx)` succeeded
- `GL_VERSION`: `OpenGL ES 3.2 Mesa 25.2.8-0ubuntu0.24.04.4`
- `GL_RENDERER`: `llvmpipe (LLVM 20.1.2, 256 bits)`
- `GL_EXT_texture_format_BGRA8888`: yes
- `GL_EXT_read_format_bgra`: yes
- `GL_OES_EGL_image`: yes
- Proc addresses Hyprland asserts: `eglCreateSyncKHR`, `eglDupNativeFenceFDANDROID`, `eglWaitSyncKHR`, `eglCreateImageKHR`, `eglQueryDmaBufFormatsEXT` all non-null
- `eglCreateSyncKHR(EGL_SYNC_NATIVE_FENCE_ANDROID)` failed with `0x3004` (`EGL_BAD_ATTRIBUTE`)
- RGBA8 renderbuffer FBO complete (`0x8cd5`); clear to green; `glReadPixels` returned `0 255 0 255`
- `eglQueryDmaBufFormatsEXT` succeeded with 69 formats. That is an import-format list. It does not allocate a dmabuf. There is still no render node and no `/dev/udmabuf` to export one.

The same pixel test passed with `EGL_PLATFORM_DEVICE_EXT` on the `EGL_MESA_device_software` device. Surfaceless is the smaller patch, because it does not need to teach `eglDeviceFromDRMFD` about a device with no DRM file. Either platform is a working llvmpipe context. GBM is not required for the context. GBM remains required only for today’s output renderbuffer, which imports a dmabuf.

So the renderer change is: when `m_drmFD < 0`, `initEGL` via `EGL_PLATFORM_SURFACELESS_MESA`, skip `openRenderNode` / `gbm_create_device`, and in `CGLRenderbuffer` if `dmabuf().success` is false and `shm().success` is true, `glRenderbufferStorage(GL_RGBA8)` (or the internal format that matches the shm fourcc) instead of `glEGLImageTargetRenderbufferStorageOES`. Headless commit does not read the mapping. `grim` does not either: it renders a second time into a `glTexImage2D` FB and readbacks. Doing one `glReadPixels` into the shm swapchain at `endRender` makes the aquamarine buffer honest and is what a later CPU consumer would read. It is optional for the `grim` proof.

`beginFullFakeRender` already draws the scene without a dmabuf. The output frame loop is what calls `initRenderBuffer` every refresh. If that call fails, the compositor logs and the output never presents, and a screenshot that re-renders the scene can still work. Wiring the renderbuffer fallback makes the frame loop succeed too, which is the difference between “grim got a picture” and “the compositor is actually running.”

## (c) Living without dmabuf

Covered in the protocol section above. For the MVP client set (`grim`, a `wl_shm` toolkit client if one is tried later):

- `grim` talks `zwlr_screencopy_v1`, receives an shm buffer description, and the compositor `glReadPixels` into it. No dmabuf global required.
- The compositor must still create a GLES context and a monitor. The monitor comes from the headless output. The output’s swapchain buffer has to be allocatable, which is the shm allocator. The output’s GL target has to be creatable without an EGL image, which is the renderbuffer fallback.
- Dmabuf-only clients, Xwayland glamor, direct scanout, and explicit sync are out of scope. They fail closed: globals are removed, `explicitSyncSupported()` is false.

Nesting under Cage, Weston, or Sway is a dead end for this goal. Those compositors on pixman do not advertise `zwp_linux_dmabuf_v1`, and `CWaylandBackend::start` treats that as fatal (`Wayland.cpp:147-149`). Even a parent that did advertise dmabuf would hand Hyprland a DRM node or nothing; a pixman parent has nothing to hand over.

## MVP patch plan

Goal of the follow-up: `Hyprland` reaches the event loop on this VM, creates one output, and `grim` writes a PNG. No `/dev/dri`. No kernel modules.

1. **Aquamarine `CSHMAllocator`.** New files next to `src/allocator/DRMDumb.cpp`. `memfd_create` + `mmap`. `BUFFER_TYPE_SHM`, `BUFFER_CAPABILITY_DATAPTR`, `XRGB8888` at minimum. `drmFD() == -1`.
2. **`CBackend::start`.** If no implementation has `drmFD() >= 0`, `primaryAllocator = CSHMAllocator::create(self)` instead of the critical log at `Backend.cpp:177`. Leave GBM in place when a fd exists.
3. **Swapchain format.** `Swapchain.cpp:55` and the trace at `:87` take `shm().format` when `dmabuf().success` is false.
4. **Hyprland EGL.** In `CHyprOpenGLImpl`, when the chosen DRM fd is `< 0` and the client extensions contain `EGL_MESA_platform_surfaceless`, `eglGetPlatformDisplayEXT(EGL_PLATFORM_SURFACELESS_MESA, ...)`, then the existing `eglInitialize` / GLES 3.2-then-3.0 / `eglMakeCurrent(NO_SURFACE)` sequence inside `initEGL`. Do not open a GBM device on that path.
5. **`CGLRenderbuffer`.** If the buffer is shm, allocate the RBO with `glRenderbufferStorage` and skip `createEGLImage`. Keep the EGLImage path for dmabuf buffers.
6. **`m_software`.** After the context is current, set it from `GL_RENDERER` containing `llvmpipe`, `softpipe`, or `softpipe`/`llvmpipe`/`Software Rasterizer` (the #16343 check). That makes `GLRenderer.cpp:115` call `glFinish`.
7. **One output.** If `m_aqBackend->drmFD() < 0` after a successful start, `createOutput` on the headless implementation immediately (name `HEADLESS-1` or the existing `FALLBACK`). The 2 second fallback would also do this; immediate is easier to test.
8. **Proof.** `grim -o <name> /tmp/out.png` against `WAYLAND_DISPLAY`. Default permissions already allow screencopy. Confirm the PNG is non-empty and not the clear color only if a client was mapped; a background clear is a valid first proof. `hyprctl monitors` should list the output. There is no `hyprctl screenshot` in 0.56.2.

Out of the MVP on purpose: pixman, udmabuf, changing the Wayland backend to start without dmabuf, Xwayland, advertising `zwp_linux_dmabuf_v1` with no device, input, and a sustained frame-rate target.

## Effort

The new code is on the order of the existing dumb allocator (about 160 lines) plus a short branch in `CBackend::start`, a format fallback in the swapchain, an EGL platform branch in `OpenGL.cpp`, and a second constructor path in `GLRenderbuffer.cpp`. Call sites that already check `fd < 0` (`syncObjSupport`, the dmabuf and `wl_drm` globals, `drmGetVersion` in the renderer) can stay.

The part that takes the time is the audit of DRM calls that assume a non-negative fd once `hasSession()` is true. `CDRMBackend::attempt` can leave a session in place after “Found no gpus”. Anything that does `drmGetDevice(m_drm.fd)` without a `< 0` check will need a guard. That is a read of `m_drm.fd` / `m_drmRenderNode.fd` uses, not a new subsystem.

Building Hyprland and aquamarine on this VM is a dependency install (hyprutils, hyprlang, wayland, libinput, libdrm, cairo, pango, and the rest of the 0.56.2 stack). It is larger than the patch. The EGL probe did not need that stack.

## Risks

- **Native fence procs are non-null and the extension is absent.** The startup asserts pass. A call to `CEGLSync::create` without checking `explicitSyncSupported()` aborts on the `RASSERT` at `OpenGL.cpp:2737`. The known `endRender` path checks the flag. The audit should confirm there is no other caller.
- **`eglQueryDmaBufFormatsEXT` succeeds with no device.** `initDRMFormats` will populate formats. The protocol code must keep removing `zwp_linux_dmabuf_v1` when `devIDFromFD` fails. If a later edit advertises those 69 formats anyway, clients will try to import dmabufs nobody can allocate.
- **Swapchain format 0** if step 3 is skipped. Frames fail in `initRenderBuffer` with `DRM_FORMAT_INVALID`.
- **`glFinish` every frame** once `m_software` is set. Correct for a screenshot. At 1080p the CPU cost is the whole point of llvmpipe. [aquamarine #351](https://github.com/hyprwm/aquamarine/issues/351) already saw single-digit fps with a vgem render node and the EGLImage path, so a readback path will be in that neighborhood. The MVP does not promise 60 Hz.
- **Session left behind after a failed GPU scan.** `hasSession()` true, `drmFD()` `-1`, `sessionDevices` empty. Renderer software-detection takes the session branch and finds nothing. Libinput may or may not come up. Do not treat `hasSession()` as “we have a GPU.”
- **Shader and extension assumptions beyond BGRA.** This Mesa has the extensions the constructor asserts. A different llvmpipe build could fail the `GL_EXT_texture_format_BGRA8888` `RASSERT` or a later shader compile. The probe should be re-run if Mesa changes.
- **10-bit formats in the headless format list.** `getRenderFormats()` includes `XRGB2101010` with a linear modifier. The shm allocator should refuse those so the swapchain does not pick them via `guessFormatFrom`’s 10-bit preference (`GBM.cpp:17-35`, used by GBM; the shm allocator needs its own smaller list or the headless list needs a CPU subset).
- **Permission dialog** if someone sets `ecosystem:enforce_permissions`. Default is off.
- **Maintainer appetite.** vaxerski has merged llvmpipe detection (#16343) and a render-node-without-KMS switch (#255), and he has said he has little interest in Windows VMs (#6053) and that Hyprland runs on one GPU (#12839). An shm allocator matches his own TODO at `Backend.cpp:162`, and it is still a feature he has not asked for. The MVP is a local patch. Upstream is a separate decision, and this stage does not propose it.

## Recommendation

Go ahead with the follow-up MVP on the surfaceless GLES plus shm-allocator plan. The blocking experiment is done: llvmpipe surfaceless contexts work on this VM, including the BGRA extension Hyprland requires, and the native-fence sync Hyprland uses for explicit sync does not.

Do the follow-up as the eight steps above. Stop the first time `grim` writes a PNG from the headless output. Leave pixman, udmabuf, and nested-under-Sway for a later redesign if the GLES path turns out to be too slow for anything but a screenshot.
