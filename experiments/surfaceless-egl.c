/*
 * Prove or disprove a GLES context on this VM with no /dev/dri.
 *
 * Tries, in order:
 *   1. EGL_MESA_platform_surfaceless
 *   2. EGL_EXT_platform_device, if any EGL device enumerates
 *
 * Then creates an EGL_NO_SURFACE GLES 3.2 (fallback 3.0) context, draws a
 * solid color into a renderbuffer FBO, and glReadPixels it back.
 *
 * Build: see experiments/README.md
 */
#define EGL_EGLEXT_PROTOTYPES
#define GL_GLEXT_PROTOTYPES

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl32.h>
#include <GLES2/gl2ext.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef EGL_PLATFORM_SURFACELESS_MESA
#define EGL_PLATFORM_SURFACELESS_MESA 0x31DD
#endif

static int g_failures = 0;

static void fail(const char *what) {
    EGLint err = eglGetError();
    fprintf(stderr, "FAIL: %s (eglGetError=0x%x, glGetError=0x%x)\n", what, err, glGetError());
    g_failures++;
}

static void section(const char *title) { printf("\n== %s ==\n", title); }

static int has_token(const char *haystack, const char *needle) {
    if (!haystack || !needle)
        return 0;
    size_t n = strlen(needle);
    for (const char *p = haystack; *p; p++) {
        if ((p == haystack || p[-1] == ' ') && strncmp(p, needle, n) == 0 && (p[n] == '\0' || p[n] == ' '))
            return 1;
    }
    return 0;
}

static void print_extensions(const char *label, const char *exts) {
    printf("%s:\n", label);
    if (!exts || !exts[0]) {
        printf("  (none)\n");
        return;
    }
    const char *interesting[] = {
        "EGL_MESA_platform_surfaceless",
        "EGL_KHR_platform_gbm",
        "EGL_EXT_platform_device",
        "EGL_EXT_device_base",
        "EGL_EXT_device_enumeration",
        "EGL_EXT_device_query",
        "EGL_EXT_device_drm",
        "EGL_MESA_device_software",
        "EGL_KHR_surfaceless_context",
        "EGL_KHR_no_config_context",
        "EGL_EXT_image_dma_buf_import",
        "EGL_EXT_image_dma_buf_import_modifiers",
        "EGL_ANDROID_native_fence_sync",
        "EGL_KHR_fence_sync",
        "EGL_KHR_wait_sync",
        NULL,
    };
    printf("  raw count of spaces: scanning tokens of interest\n");
    for (int i = 0; interesting[i]; i++)
        printf("  %-44s %s\n", interesting[i], has_token(exts, interesting[i]) ? "yes" : "no");
}

static EGLDisplay try_surfaceless(void) {
    section("platform surfaceless");
    const char *client = eglQueryString(EGL_NO_DISPLAY, EGL_EXTENSIONS);
    print_extensions("client extensions", client);
    if (!has_token(client, "EGL_MESA_platform_surfaceless")) {
        printf("EGL_MESA_platform_surfaceless is not a client extension\n");
        return EGL_NO_DISPLAY;
    }

    PFNEGLGETPLATFORMDISPLAYEXTPROC getPlatformDisplay =
        (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
    if (!getPlatformDisplay) {
        fail("eglGetPlatformDisplayEXT");
        return EGL_NO_DISPLAY;
    }

    EGLDisplay dpy = getPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, NULL);
    if (dpy == EGL_NO_DISPLAY) {
        fail("eglGetPlatformDisplayEXT(SURFACELESS)");
        return EGL_NO_DISPLAY;
    }
    printf("surfaceless display: %p\n", (void *)dpy);
    return dpy;
}

static void list_devices(void) {
    section("EGL devices");
    PFNEGLQUERYDEVICESEXTPROC queryDevices = (PFNEGLQUERYDEVICESEXTPROC)eglGetProcAddress("eglQueryDevicesEXT");
    PFNEGLQUERYDEVICESTRINGEXTPROC queryString =
        (PFNEGLQUERYDEVICESTRINGEXTPROC)eglGetProcAddress("eglQueryDeviceStringEXT");
    if (!queryDevices) {
        printf("eglQueryDevicesEXT: unavailable\n");
        return;
    }
    EGLint n = 0;
    if (!queryDevices(0, NULL, &n)) {
        fail("eglQueryDevicesEXT count");
        return;
    }
    printf("device count: %d\n", n);
    if (n <= 0)
        return;
    EGLDeviceEXT *devs = calloc((size_t)n, sizeof(*devs));
    if (!devs || !queryDevices(n, devs, &n)) {
        fail("eglQueryDevicesEXT list");
        free(devs);
        return;
    }
    for (EGLint i = 0; i < n; i++) {
        const char *ext = queryString ? queryString(devs[i], EGL_EXTENSIONS) : NULL;
        const char *drm = NULL;
#ifdef EGL_DRM_DEVICE_FILE_EXT
        if (queryString)
            drm = queryString(devs[i], EGL_DRM_DEVICE_FILE_EXT);
#endif
        printf("device[%d] %p drm=%s\n  exts: %s\n", i, (void *)devs[i], drm ? drm : "(null)", ext ? ext : "(null)");
    }
    free(devs);
}

static int render_one_pixel(EGLDisplay dpy, const char *label) {
    section(label);
    EGLint major = 0, minor = 0;
    if (!eglInitialize(dpy, &major, &minor)) {
        fail("eglInitialize");
        return 0;
    }
    printf("EGL version: %d.%d\n", major, minor);
    printf("EGL vendor: %s\n", eglQueryString(dpy, EGL_VENDOR));
    print_extensions("display extensions", eglQueryString(dpy, EGL_EXTENSIONS));

    if (!eglBindAPI(EGL_OPENGL_ES_API)) {
        fail("eglBindAPI");
        return 0;
    }

    const EGLint attrs32[] = {EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 2, EGL_NONE};
    EGLContext ctx = eglCreateContext(dpy, EGL_NO_CONFIG_KHR, EGL_NO_CONTEXT, attrs32);
    int gles_minor = 2;
    if (ctx == EGL_NO_CONTEXT) {
        printf("GLES 3.2 context failed, retrying 3.0\n");
        const EGLint attrs30[] = {EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 0, EGL_NONE};
        ctx = eglCreateContext(dpy, EGL_NO_CONFIG_KHR, EGL_NO_CONTEXT, attrs30);
        gles_minor = 0;
    }
    if (ctx == EGL_NO_CONTEXT) {
        fail("eglCreateContext");
        return 0;
    }
    if (!eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx)) {
        fail("eglMakeCurrent(NO_SURFACE)");
        return 0;
    }

    printf("GL_VERSION:  %s\n", (const char *)glGetString(GL_VERSION));
    printf("GL_VENDOR:   %s\n", (const char *)glGetString(GL_VENDOR));
    printf("GL_RENDERER: %s\n", (const char *)glGetString(GL_RENDERER));
    const char *glext = (const char *)glGetString(GL_EXTENSIONS);
    printf("GL_EXT_texture_format_BGRA8888: %s\n", has_token(glext, "GL_EXT_texture_format_BGRA8888") ? "yes" : "no");
    printf("GL_EXT_read_format_bgra:        %s\n", has_token(glext, "GL_EXT_read_format_bgra") ? "yes" : "no");
    printf("GL_OES_EGL_image:               %s\n", has_token(glext, "GL_OES_EGL_image") ? "yes" : "no");
    printf("GL_OES_EGL_image_external:      %s\n", has_token(glext, "GL_OES_EGL_image_external") ? "yes" : "no");

    /* Hyprland 0.56.2 RASSERTs these proc addresses in CHyprOpenGLImpl. */
    const char *procs[] = {"eglCreateSyncKHR", "eglDestroySyncKHR", "eglDupNativeFenceFDANDROID", "eglWaitSyncKHR",
                           "eglCreateImageKHR", "eglQueryDmaBufFormatsEXT", "eglQueryDmaBufModifiersEXT", NULL};
    for (int i = 0; procs[i]; i++) {
        void *p = (void *)eglGetProcAddress(procs[i]);
        printf("proc %-32s %s\n", procs[i], p ? "non-null" : "NULL");
    }

    PFNEGLCREATESYNCKHRPROC createSync = (PFNEGLCREATESYNCKHRPROC)eglGetProcAddress("eglCreateSyncKHR");
    if (createSync) {
        EGLSyncKHR sync = createSync(dpy, EGL_SYNC_NATIVE_FENCE_ANDROID, NULL);
        printf("eglCreateSyncKHR(NATIVE_FENCE_ANDROID): %s (err=0x%x)\n", sync != EGL_NO_SYNC_KHR ? "ok" : "failed", eglGetError());
        if (sync != EGL_NO_SYNC_KHR) {
            PFNEGLDESTROYSYNCKHRPROC destroySync = (PFNEGLDESTROYSYNCKHRPROC)eglGetProcAddress("eglDestroySyncKHR");
            if (destroySync)
                destroySync(dpy, sync);
        }
    }

    GLuint rbo = 0, fbo = 0;
    glGenRenderbuffers(1, &rbo);
    glBindRenderbuffer(GL_RENDERBUFFER, rbo);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, 2, 2);
    glGenFramebuffers(1, &fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rbo);
    GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    printf("FBO status: 0x%x (%s)\n", status, status == GL_FRAMEBUFFER_COMPLETE ? "complete" : "incomplete");
    if (status != GL_FRAMEBUFFER_COMPLETE) {
        fail("framebuffer");
        return 0;
    }

    glClearColor(0.0f, 1.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    glFinish();

    unsigned char px[4] = {0, 0, 0, 0};
    glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
    GLenum glerr = glGetError();
    printf("glReadPixels RGBA: %u %u %u %u (glGetError=0x%x) gles 3.%d\n", px[0], px[1], px[2], px[3], glerr, gles_minor);
    int ok = (glerr == GL_NO_ERROR && px[0] == 0 && px[1] == 255 && px[2] == 0 && px[3] == 255);
    printf("pixel match (0,255,0,255): %s\n", ok ? "yes" : "no");
    if (!ok)
        g_failures++;

    PFNEGLQUERYDMABUFFORMATSEXTPROC queryFormats =
        (PFNEGLQUERYDMABUFFORMATSEXTPROC)eglGetProcAddress("eglQueryDmaBufFormatsEXT");
    if (queryFormats) {
        EGLint len = 0;
        EGLBoolean q = queryFormats(dpy, 0, NULL, &len);
        printf("eglQueryDmaBufFormatsEXT count: %s len=%d err=0x%x\n", q ? "ok" : "failed", len, eglGetError());
    }

    glDeleteFramebuffers(1, &fbo);
    glDeleteRenderbuffers(1, &rbo);
    eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroyContext(dpy, ctx);
    eglTerminate(dpy);
    return ok;
}

static EGLDisplay try_software_device(void) {
    section("platform device (MESA software)");
    PFNEGLQUERYDEVICESEXTPROC queryDevices = (PFNEGLQUERYDEVICESEXTPROC)eglGetProcAddress("eglQueryDevicesEXT");
    PFNEGLQUERYDEVICESTRINGEXTPROC queryString =
        (PFNEGLQUERYDEVICESTRINGEXTPROC)eglGetProcAddress("eglQueryDeviceStringEXT");
    PFNEGLGETPLATFORMDISPLAYEXTPROC getPlatformDisplay =
        (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
    if (!queryDevices || !queryString || !getPlatformDisplay) {
        printf("device platform procs missing\n");
        return EGL_NO_DISPLAY;
    }
    EGLint n = 0;
    if (!queryDevices(0, NULL, &n) || n <= 0)
        return EGL_NO_DISPLAY;
    EGLDeviceEXT *devs = calloc((size_t)n, sizeof(*devs));
    if (!devs || !queryDevices(n, devs, &n)) {
        free(devs);
        return EGL_NO_DISPLAY;
    }
    EGLDeviceEXT software = EGL_NO_DEVICE_EXT;
    for (EGLint i = 0; i < n; i++) {
        const char *ext = queryString(devs[i], EGL_EXTENSIONS);
        if (ext && has_token(ext, "EGL_MESA_device_software"))
            software = devs[i];
    }
    free(devs);
    if (software == EGL_NO_DEVICE_EXT) {
        printf("no EGL_MESA_device_software device\n");
        return EGL_NO_DISPLAY;
    }
    EGLDisplay dpy = getPlatformDisplay(EGL_PLATFORM_DEVICE_EXT, software, NULL);
    printf("device display: %p\n", (void *)dpy);
    return dpy;
}

int main(void) {
    printf("surfaceless EGL + GLES probe\n");
    printf("EGL_NO_DISPLAY client vendor: %s\n", eglQueryString(EGL_NO_DISPLAY, EGL_VENDOR));
    printf("EGL_NO_DISPLAY client version: %s\n", eglQueryString(EGL_NO_DISPLAY, EGL_VERSION));

    list_devices();

    EGLDisplay dpy = try_surfaceless();
    int ok = 0;
    if (dpy != EGL_NO_DISPLAY)
        ok = render_one_pixel(dpy, "render via surfaceless");

    EGLDisplay devDpy = try_software_device();
    int dev_ok = 0;
    if (devDpy != EGL_NO_DISPLAY)
        dev_ok = render_one_pixel(devDpy, "render via EGL device platform");

    printf("\nRESULT: surfaceless %s, device-platform %s (%d failure notes)\n", ok ? "PASS" : "FAIL", dev_ok ? "PASS" : "FAIL",
           g_failures);
    return ok ? 0 : 1;
}
