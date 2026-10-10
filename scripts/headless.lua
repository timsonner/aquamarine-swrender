hl.monitor({
    output = "HEADLESS-1",
    mode = "1920x1080@60",
    position = "0x0",
    scale = "1",
})

hl.config({
    general = {
        gaps_in = 8,
        gaps_out = 80,
        border_size = 8,
        col = {
            active_border = "rgba(ff8800ff)",
            inactive_border = "rgba(ff8800ff)",
        },
    },
    decoration = {
        rounding = 0,
        shadow = { enabled = false },
        blur = { enabled = false },
    },
    misc = {
        force_default_wallpaper = 0,
        disable_hyprland_guiutils_check = true,
        disable_xdg_env_checks = true,
        disable_watchdog_warning = true,
    },
    debug = {
        disable_logs = false,
    },
})
