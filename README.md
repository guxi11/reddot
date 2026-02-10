# Reddot

A macOS menubar utility that monitors Dock badge changes and automatically brings the corresponding app to the foreground. It also provides a vimium-like label navigation mode (triggered by `Control+F`) to quickly jump to badged apps.

## Features

- **Badge Monitoring** - Detects Dock icon badge changes via Accessibility API
- **Auto-Switch** - Automatically activates the app when a new badge appears
- **Vimium-like Navigation** - Press `Control+F` to enter label mode and jump to any badged app

## Requirements

- macOS 13.0+
- **Accessibility** permission (required)

## Install

Download `Reddot.zip` from [Releases](../../releases/latest), unzip and drag `Reddot.app` to Applications.

## Build from Source

Open `Reddot/Reddot.xcodeproj` in Xcode and build.

## License

MIT
