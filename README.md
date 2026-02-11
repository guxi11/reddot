# Reddot

A macOS menubar utility that monitors Dock badge changes and automatically brings the corresponding app to the foreground. It also provides a vimium-like label navigation mode (triggered by `Control+F`) to quickly jump to badged apps.

## Features

- **Badge Monitoring** - Detects Dock icon badge changes via Accessibility API
- **Auto-Switch** - Automatically activates the app when a new badge appears
- **Vimium-like Navigation** - Press `Control+F` to enter label mode and jump to any badged app
- **Persistent Hint Mode** - Keep clicking red dots one after another without re-triggering `Control+F`
- **Ignored Apps** - Exclude specific apps from auto-activation
- **Configurable Throttle & Cooldown** - Tune timing parameters from the menu bar

### Vimium-like Navigation

Press `Control+F` to enter label mode. Each detected badge is assigned a stable letter label. Press the corresponding letter to click the badge, or `Esc` to cancel.

![Vim mode demo](docs/demo.png)

### Persistent Hint Mode

Enable **Persistent Hint Mode** from the menu bar to stay in label mode after clicking a red dot. After each click, Reddot waits briefly for the page to respond, then re-scans and shows updated labels for remaining red dots. Press `Esc` at any time to exit.

### Ignored Apps

Open the **Ignored Apps** submenu to see all apps that currently have a Dock badge. Check an app to exclude it from auto-activation. The list updates dynamically; previously ignored apps that are no longer in the Dock are still shown so you can un-ignore them.

### Throttle & Input Cooldown

Both values are now configurable from the menu bar:

- **Throttle Interval** (5s / 10s / 30s / 60s, default 10s) - Same app badge changes within this window are ignored after the first trigger.
- **Input Cooldown** (1s / 3s / 5s, default 3s) - After the user stops typing, Reddot waits this long before activating an app.

### Input-aware Activation

Reddot will **not** switch apps while you are typing. It monitors keyboard activity (keyDown and flagsChanged events) and detects IME composing state (marked text). If the user is actively typing or has typed within the cooldown period, app activation is deferred and retried every 0.5s until the user is idle.

## Requirements

- macOS 13.0+
- **Accessibility** permission (required)
- **Screen Recording** permission (required for Vimium-like navigation)

## Install

Download `Reddot.zip` from [Releases](../../releases/latest), unzip and drag `Reddot.app` to Applications.

If macOS shows *"Reddot is damaged and can't be opened"*, run:

```bash
xattr -cr /Applications/Reddot.app
```

## Build from Source

Open `Reddot/Reddot.xcodeproj` in Xcode and build.

## License

MIT
