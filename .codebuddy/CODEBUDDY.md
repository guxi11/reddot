# Reddot - Project Context

## Overview

macOS menubar utility that monitors Dock badge changes and provides vimium-style red dot navigation. Pure Swift + AppKit, no third-party dependencies.

## Architecture

```
Reddot/Reddot/
├── ReddotApp.swift            # Entry point + AppDelegate (menu bar, permissions, UserDefaults)
├── DockBadgeMonitor.swift     # Accessibility API polling for Dock badge changes
├── VimModeController.swift    # Global hotkey (Ctrl+F) + hint label overlay + click simulation
├── RedDotImageDetector.swift  # ScreenCaptureKit-based red dot image detection (HSB + connected components)
├── HintOverlayWindow.swift    # Floating label overlay windows (vimium-style)
└── ModeIndicatorWindow.swift  # Floating HUD for mode status display
```

## Core Flow

1. **Badge Monitoring**: `DockBadgeMonitor` polls Dock process via Accessibility API every 1s, detects `AXStatusLabel` changes on dock items, fires callback with throttling + input-aware deferral.
2. **Auto-Activation**: `AppDelegate` receives badge change callback -> `NSRunningApplication.activate()` to bring app to foreground.
3. **Vimium Navigation**: `VimModeController` installs `CGEventTap` -> `Ctrl+F` triggers `RedDotImageDetector.detectAsync()` -> shows `HintOverlayWindow` with letter labels -> user presses letter -> `simulateClick()` at detected position.

## Key Design Decisions

- **Pure MenuBar app**: `NSApp.setActivationPolicy(.accessory)`, no Dock icon, no main window.
- **NSMenu submenus for settings**: All configuration (ignored apps, throttle, cooldown, persistent mode) lives in menu bar dropdown submenus. No separate settings window.
- **UserDefaults for persistence**: Keys: `ignoredBundleIds` ([String]), `throttleInterval` (Double), `inputCooldown` (Double), `persistentHintMode` (Bool), `autoActivationDisableUntil` (Date).
- **NSMenuDelegate**: `menuNeedsUpdate(_:)` rebuilds dynamic submenus (ignored apps list, option checkmarks) each time the menu opens.
- **CGEventTap for global hotkeys**: Intercepts keyDown events system-wide. In hint mode, all keys are consumed; only Esc and matching letter keys are handled.

## Configurable Parameters

| Parameter | UserDefaults Key | Default | Options |
|-----------|-----------------|---------|---------|
| Throttle Interval | `throttleInterval` | 10s | 5s, 10s, 30s, 60s |
| Input Cooldown | `inputCooldown` | 3s | 1s, 3s, 5s |
| Ignored Apps | `ignoredBundleIds` | [] | Dynamic list from detected badges |
| Persistent Hint Mode | `persistentHintMode` | false | on/off toggle |
| Pause Auto-Activation | `autoActivationDisableUntil` | nil | 30min, 1hr |

## Permissions Required

- **Accessibility** (AXUIElement, CGEventTap) - mandatory
- **Screen Recording** (ScreenCaptureKit) - required for red dot image detection

## Build

Xcode project at `Reddot/Reddot.xcodeproj`. Target: macOS 13.0+. No package dependencies.

```bash
xcodebuild -project Reddot/Reddot.xcodeproj -scheme Reddot -configuration Debug build
```

## Conventions

- Logging prefix: `[Reddot]`
- Menu item tags: 100 (Ignored Apps), 101 (Throttle), 102 (Cooldown), 103 (Persistent Hint Mode)
- All UI operations on main thread; badge scanning and click simulation on background threads
