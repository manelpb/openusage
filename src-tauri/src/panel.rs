use objc2_app_kit::NSScreen;
use objc2_foundation::MainThreadMarker as Mtm;
use tauri::{AppHandle, Manager, Position, Size};
use tauri_nspanel::{
    CollectionBehavior, ManagerExt, PanelLevel, StyleMask, WebviewWindowExt, tauri_panel,
};

/// Overlap between the panel's top edge and the tray icon, in points.
const NUDGE_UP: f64 = 6.0;

/// A display's frame in macOS Cocoa global coordinates: origin is the
/// bottom-left of the main (menu-bar) display, points, Y increases upward.
#[derive(Clone, Copy, Debug)]
struct ScreenRect {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    scale: f64,
}

unsafe fn set_panel_frame_top_left(panel: &tauri_nspanel::NSPanel, x: f64, y: f64) {
    let point = tauri_nspanel::NSPoint::new(x, y);
    let _: () = objc2::msg_send![panel, setFrameTopLeftPoint: point];
}

/// Collect every screen's Cocoa frame plus the index of the main (menu-bar)
/// display — the one whose origin sits at (0, 0), which is `CGMainDisplayID`.
fn cocoa_screens(mtm: Mtm) -> (Vec<ScreenRect>, usize) {
    let screens = NSScreen::screens(mtm);
    let mut out = Vec::with_capacity(screens.len());
    let mut main_idx = 0usize;
    for (i, screen) in screens.iter().enumerate() {
        let f = screen.frame();
        if f.origin.x == 0.0 && f.origin.y == 0.0 {
            main_idx = i;
        }
        out.push(ScreenRect {
            x: f.origin.x,
            y: f.origin.y,
            w: f.size.width,
            h: f.size.height,
            scale: screen.backingScaleFactor(),
        });
    }
    (out, main_idx)
}

/// Compute the panel's top-left point in Cocoa global coordinates.
///
/// The tray rect Tauri hands us (`tray-icon` crate) is *not* in winit's
/// virtual-pixel space — it is points measured from the main display's top,
/// then multiplied by the *icon's own screen* backing scale factor:
///   `phys = pts * scale_iconscreen`, Y measured top-down from the main display.
/// With a single scale factor this is invertible with a constant, but across
/// monitors with different scales there is no single constant — which is why
/// the panel used to land off-screen on multi-monitor setups.
///
/// We recover the true Cocoa point by hypothesising the icon is on each screen
/// in turn (using that screen's scale) and keeping the hypothesis whose
/// resulting icon center actually falls inside that screen's frame.
///
/// Scale-decoding is ambiguous: dividing `icon_phys` by the *wrong* screen's
/// scale can land the point inside a different (e.g. wider, higher-scale)
/// screen — a false positive. So we test the **active screen first**
/// (`active_idx`, from `NSScreen.mainScreen`). With "Displays have separate
/// Spaces", clicking a menu bar makes that display active, so the active screen
/// is the icon's real screen; its own-scale decode lands inside itself before
/// any false positive elsewhere. The remaining screens are the fallback for
/// shortcut-triggered shows or single-menu-bar setups.
fn compute_panel_top_left(
    screens: &[ScreenRect],
    main_idx: usize,
    active_idx: Option<usize>,
    main_height_pts: f64,
    icon_phys_x: f64,
    icon_phys_y: f64,
    icon_phys_w: f64,
    icon_phys_h: f64,
    panel_width_pts: f64,
    nudge_up: f64,
) -> (f64, f64) {
    let place_on = |s: &ScreenRect| -> (f64, f64) {
        let scale = s.scale;
        let icon_x = icon_phys_x / scale;
        let icon_top_y = main_height_pts - (icon_phys_y / scale);
        let icon_w = icon_phys_w / scale;
        let icon_h = icon_phys_h / scale;

        let center_x = icon_x + icon_w / 2.0;
        let mut panel_x = center_x - panel_width_pts / 2.0;
        // Keep the panel within the chosen screen's horizontal bounds.
        let max_x = s.x + s.w - panel_width_pts;
        if panel_x > max_x {
            panel_x = max_x;
        }
        if panel_x < s.x {
            panel_x = s.x;
        }

        // Panel top edge tucks under the icon's bottom, nudged up to overlap.
        let mut panel_top_y = (icon_top_y - icon_h) + nudge_up;
        // Don't push the top edge above the screen (auto-hidden menu bar puts
        // the tray rect above the visible screen, which would clip the panel).
        let screen_top = s.y + s.h;
        if panel_top_y > screen_top {
            panel_top_y = screen_top;
        }
        (panel_x, panel_top_y)
    };

    // Active screen first, then the rest (skipping the active one).
    let order = active_idx
        .filter(|&a| a < screens.len())
        .into_iter()
        .chain((0..screens.len()).filter(|&i| Some(i) != active_idx));

    for i in order {
        let s = &screens[i];
        let scale = s.scale;
        let icon_x = icon_phys_x / scale;
        let icon_top_y = main_height_pts - (icon_phys_y / scale);
        let center_x = icon_x + (icon_phys_w / scale) / 2.0;
        let center_y = icon_top_y - (icon_phys_h / scale) / 2.0;
        let inside =
            center_x >= s.x && center_x < s.x + s.w && center_y >= s.y && center_y < s.y + s.h;
        if inside {
            log::debug!("position_panel: matched screen[{}] (scale {})", i, scale);
            return place_on(s);
        }
    }

    log::warn!(
        "position_panel: no screen matched tray rect ({:.0}, {:.0}); using main display",
        icon_phys_x,
        icon_phys_y
    );
    match screens.get(main_idx) {
        Some(s) => place_on(s),
        None => (0.0, 0.0),
    }
}

/// Position the panel under the tray icon. Must be called on the main thread
/// (NSScreen access requires it); no-ops with a warning otherwise.
fn place_panel(
    panel: &tauri_nspanel::NSPanel,
    icon_phys_x: f64,
    icon_phys_y: f64,
    icon_phys_w: f64,
    icon_phys_h: f64,
    panel_width: f64,
) {
    let Some(mtm) = Mtm::new() else {
        log::warn!("place_panel called off the main thread");
        return;
    };
    let (screens, main_idx) = cocoa_screens(mtm);
    if screens.is_empty() {
        log::warn!("place_panel: no screens reported");
        return;
    }

    // Identify the active screen (NSScreen.mainScreen) and match it to our list
    // by frame origin, so resolution can try it first. With "Displays have
    // separate Spaces", clicking a menu bar makes that display active, so this
    // is the screen the tray icon was clicked on.
    let active_idx = NSScreen::mainScreen(mtm).and_then(|main_screen| {
        let f = main_screen.frame();
        screens
            .iter()
            .position(|s| (s.x - f.origin.x).abs() < 1.0 && (s.y - f.origin.y).abs() < 1.0)
    });

    let main_height = screens[main_idx].h;
    let (x, y) = compute_panel_top_left(
        &screens,
        main_idx,
        active_idx,
        main_height,
        icon_phys_x,
        icon_phys_y,
        icon_phys_w,
        icon_phys_h,
        panel_width,
        NUDGE_UP,
    );
    unsafe {
        set_panel_frame_top_left(panel, x, y);
    }
}

/// Macro to get existing panel or initialize it if needed.
/// Returns Option<Panel> - Some if panel is available, None on error.
macro_rules! get_or_init_panel {
    ($app_handle:expr) => {
        match $app_handle.get_webview_panel("main") {
            Ok(panel) => Some(panel),
            Err(_) => {
                if let Err(err) = crate::panel::init($app_handle) {
                    log::error!("Failed to init panel: {}", err);
                    None
                } else {
                    match $app_handle.get_webview_panel("main") {
                        Ok(panel) => Some(panel),
                        Err(err) => {
                            log::error!("Panel missing after init: {:?}", err);
                            None
                        }
                    }
                }
            }
        }
    };
}

// Export macro for use in other modules
pub(crate) use get_or_init_panel;

/// Retrieve the tray icon rect and position the panel beneath it.
/// No-ops gracefully if the tray icon or its rect is unavailable.
fn position_panel_from_tray(app_handle: &AppHandle) {
    let Some(tray) = app_handle.tray_by_id("tray") else {
        log::debug!("position_panel_from_tray: tray icon not found");
        return;
    };
    match tray.rect() {
        Ok(Some(rect)) => {
            position_panel_at_tray_icon(app_handle, rect.position, rect.size);
        }
        Ok(None) => {
            log::debug!("position_panel_from_tray: tray rect not available yet");
        }
        Err(e) => {
            log::warn!("position_panel_from_tray: failed to get tray rect: {}", e);
        }
    }
}

/// Show the panel (initializing if needed), positioned under the tray icon.
pub fn show_panel(app_handle: &AppHandle) {
    if let Some(panel) = get_or_init_panel!(app_handle) {
        panel.show_and_make_key();
        position_panel_from_tray(app_handle);
    }
}

/// Toggle panel visibility. If visible, hide it. If hidden, show it.
/// Used by global shortcut handler.
pub fn toggle_panel(app_handle: &AppHandle) {
    let Some(panel) = get_or_init_panel!(app_handle) else {
        return;
    };

    if panel.is_visible() {
        log::debug!("toggle_panel: hiding panel");
        panel.hide();
    } else {
        log::debug!("toggle_panel: showing panel");
        panel.show_and_make_key();
        position_panel_from_tray(app_handle);
    }
}

// Define our panel class and event handler together
tauri_panel! {
    panel!(OpenUsagePanel {
        config: {
            can_become_key_window: true,
            is_floating_panel: true
        }
    })

    panel_event!(OpenUsagePanelEventHandler {
        window_did_resign_key(notification: &NSNotification) -> ()
    })
}

pub fn init(app_handle: &tauri::AppHandle) -> tauri::Result<()> {
    if app_handle.get_webview_panel("main").is_ok() {
        return Ok(());
    }

    let window = app_handle.get_webview_window("main").unwrap();

    let panel = window.to_panel::<OpenUsagePanel>()?;

    // Disable native shadow - it causes gray border on transparent windows
    // Let CSS handle shadow via shadow-xl class
    panel.set_has_shadow(false);
    panel.set_opaque(false);

    // Configure panel behavior
    panel.set_level(PanelLevel::MainMenu.value() + 1);

    panel.set_collection_behavior(
        CollectionBehavior::new()
            .move_to_active_space()
            .full_screen_auxiliary()
            .value(),
    );

    panel.set_style_mask(StyleMask::empty().nonactivating_panel().value());

    // Set up event handler to hide panel when it loses focus
    let event_handler = OpenUsagePanelEventHandler::new();

    let handle = app_handle.clone();
    event_handler.window_did_resign_key(move |_notification| {
        if let Ok(panel) = handle.get_webview_panel("main") {
            panel.hide();
        }
    });

    panel.set_event_handler(Some(event_handler.as_ref()));

    Ok(())
}

pub fn position_panel_at_tray_icon(
    app_handle: &tauri::AppHandle,
    icon_position: Position,
    icon_size: Size,
) {
    let window = app_handle.get_webview_window("main").unwrap();

    let (icon_phys_x, icon_phys_y) = match &icon_position {
        Position::Physical(pos) => (pos.x as f64, pos.y as f64),
        Position::Logical(pos) => (pos.x, pos.y),
    };
    let (icon_phys_w, icon_phys_h) = match &icon_size {
        Size::Physical(s) => (s.width as f64, s.height as f64),
        Size::Logical(s) => (s.width, s.height),
    };

    // Read panel width from the window, converted to logical points.
    // outer_size() returns physical pixels at the window's current scale factor.
    // If the window isn't available yet, parse the configured width from tauri.conf.json
    // (embedded at compile time) so it stays in sync automatically.
    let panel_width = match (window.outer_size(), window.scale_factor()) {
        (Ok(s), Ok(win_scale)) => s.width as f64 / win_scale,
        _ => {
            let conf: serde_json::Value = serde_json::from_str(include_str!("../tauri.conf.json"))
                .expect("tauri.conf.json must be valid JSON");
            conf["app"]["windows"][0]["width"]
                .as_f64()
                .expect("width must be set in tauri.conf.json")
        }
    };

    let Ok(panel_handle) = app_handle.get_webview_panel("main") else {
        return;
    };

    // NSScreen access (inside place_panel) must happen on the main thread.
    if Mtm::new().is_some() {
        place_panel(
            panel_handle.as_panel(),
            icon_phys_x,
            icon_phys_y,
            icon_phys_w,
            icon_phys_h,
            panel_width,
        );
        return;
    }

    let (tx, rx) = std::sync::mpsc::channel();
    let panel_handle = panel_handle.clone();
    if let Err(error) = window.run_on_main_thread(move || {
        place_panel(
            panel_handle.as_panel(),
            icon_phys_x,
            icon_phys_y,
            icon_phys_w,
            icon_phys_h,
            panel_width,
        );
        let _ = tx.send(());
    }) {
        log::warn!("Failed to position panel on main thread: {}", error);
        return;
    }

    if rx.recv().is_err() {
        log::warn!("Failed waiting for panel position on main thread");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Build a tray rect (as `tray-icon` reports it) for an icon at a known
    // Cocoa point on a given screen: phys = pts * icon_screen_scale, with Y
    // measured top-down from the main display top.
    fn tray_rect(
        main_height: f64,
        scale: f64,
        cocoa_top_x: f64,
        cocoa_top_y: f64,
        w_pts: f64,
        h_pts: f64,
    ) -> (f64, f64, f64, f64) {
        let phys_x = cocoa_top_x * scale;
        let phys_y = (main_height - cocoa_top_y) * scale;
        (phys_x, phys_y, w_pts * scale, h_pts * scale)
    }

    #[test]
    fn single_retina_screen_centers_under_icon() {
        let screens = [ScreenRect { x: 0.0, y: 0.0, w: 1440.0, h: 900.0, scale: 2.0 }];
        let main_h = 900.0;
        // Icon top-left at Cocoa (1200, 898), 24x22 pts, near the menu bar.
        let (ix, iy, iw, ih) = tray_rect(main_h, 2.0, 1200.0, 898.0, 24.0, 22.0);

        let (px, py) =
            compute_panel_top_left(&screens, 0, Some(0), main_h, ix, iy, iw, ih, 320.0, 6.0);

        // Centered: 1200 + 12 - 160 = 1052; top: (898 - 22) + 6 = 882.
        assert!((px - 1052.0).abs() < 0.01, "px = {px}");
        assert!((py - 882.0).abs() < 0.01, "py = {py}");
    }

    #[test]
    fn icon_on_secondary_with_different_scale_resolves_to_secondary() {
        // Main: 1440x900 @2x at origin. Secondary: 1920x1080 @1x to the right.
        let screens = [
            ScreenRect { x: 0.0, y: 0.0, w: 1440.0, h: 900.0, scale: 2.0 },
            ScreenRect { x: 1440.0, y: 0.0, w: 1920.0, h: 1080.0, scale: 1.0 },
        ];
        let main_h = 900.0;
        // Icon physically on the secondary screen, Cocoa top-left (1540, 1058).
        let (ix, iy, iw, ih) = tray_rect(main_h, 1.0, 1540.0, 1058.0, 24.0, 22.0);

        // Clicked the secondary's menu bar -> it's the active screen.
        let (px, py) =
            compute_panel_top_left(&screens, 0, Some(1), main_h, ix, iy, iw, ih, 320.0, 6.0);

        // Must land on the secondary screen, not be flung off by the main flip.
        assert!(px >= 1440.0 && px + 320.0 <= 1440.0 + 1920.0, "px = {px}");
        assert!(py <= 1080.0 && py > 1000.0, "py = {py}");
    }

    // Regression: exact geometry from the real multi-monitor bug report.
    // Laptop 1512x982 @2x at origin (main), external 1720x1440 @1x at (1512,-458),
    // menu bars top-aligned at Cocoa y=982. Clicking the external tray reported
    // icon_phys=(2570,0 75x30). The scan alone false-matched the laptop because
    // 2570/2=1285 lands inside [0,1512); active-first resolves it correctly.
    #[test]
    fn external_click_resolves_to_external_not_laptop() {
        let screens = [
            ScreenRect { x: 0.0, y: 0.0, w: 1512.0, h: 982.0, scale: 2.0 },
            ScreenRect { x: 1512.0, y: -458.0, w: 1720.0, h: 1440.0, scale: 1.0 },
        ];
        let main_h = 982.0;
        let (ix, iy, iw, ih) = (2570.0, 0.0, 75.0, 30.0);

        // Active screen is the external (where the menu bar was clicked).
        let (px, _py) =
            compute_panel_top_left(&screens, 0, Some(1), main_h, ix, iy, iw, ih, 400.0, 6.0);
        assert!(px >= 1512.0, "should land on external, px = {px}");

        // Without the active hint, the scan false-matches the laptop — this is
        // the original bug, and why the active-screen hint is required.
        let (px_buggy, _) =
            compute_panel_top_left(&screens, 0, None, main_h, ix, iy, iw, ih, 400.0, 6.0);
        assert!(px_buggy < 1512.0, "scan-only reproduces the laptop false-match");
    }

    #[test]
    fn panel_clamped_to_right_edge() {
        let screens = [ScreenRect { x: 0.0, y: 0.0, w: 1440.0, h: 900.0, scale: 2.0 }];
        let main_h = 900.0;
        // Icon near the right edge would push the panel off-screen without clamp.
        let (ix, iy, iw, ih) = tray_rect(main_h, 2.0, 1430.0, 898.0, 24.0, 22.0);

        let (px, _py) =
            compute_panel_top_left(&screens, 0, Some(0), main_h, ix, iy, iw, ih, 320.0, 6.0);

        assert!((px - (1440.0 - 320.0)).abs() < 0.01, "px = {px}");
    }

    #[test]
    fn auto_hidden_menubar_clamps_top_to_screen() {
        let screens = [ScreenRect { x: 0.0, y: 0.0, w: 1440.0, h: 900.0, scale: 2.0 }];
        let main_h = 900.0;
        // Tray rect sits above the visible screen (icon top at Cocoa y = 905).
        let (ix, iy, iw, ih) = tray_rect(main_h, 2.0, 1200.0, 905.0, 24.0, 22.0);

        let (_px, py) =
            compute_panel_top_left(&screens, 0, Some(0), main_h, ix, iy, iw, ih, 320.0, 6.0);

        assert!(py <= 900.0, "py = {py}");
    }
}
