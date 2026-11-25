<p align="center">
  <img src="Resources/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="128" alt="DropShelf icon">
</p>

<h1 align="center">DropShelf</h1>

<p align="center">A floating shelf for macOS to temporarily park files, images, text and links.</p>

DropShelf is a small macOS menu bar app. Drop things onto a floating shelf, then drag them out again somewhere else or send them off.

## Features

- **Floating shelf** with a glass look, visible on all Spaces, freely movable
- **Drag in and out** of files, images, text and URLs, singly or as a stack (hold Option to copy)
- **Send** via AirDrop, Messages, Mail and Share…
- **Actions**: Quick Look (Space), compress as ZIP, reveal in Finder, copy paths
- **History** of previous shelves
- **Shake to open**: shake the mouse while dragging a file and a shelf opens at the pointer
- **Settings**: auto-close, "Clear shelf?" prompt after AirDrop, glass intensity, animations (respects "Reduce motion"), launch at login

## Keyboard shortcuts

| Action | Default |
|---|---|
| New shelf at the mouse | ⌃⌥Space |
| Send the active shelf via AirDrop | ⌃⌥A |
| Open history | ⌃⌥V |

Shortcuts can be re-recorded under Settings › Shortcuts (they need at least ⌃, ⌥ or ⌘) or turned off.

## Requirements

- macOS 14 or later
- To build from source: Xcode (Swift 6) and [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Install

Download the DMG from the [Releases](https://github.com/Horn2208/DropShelf/releases) page and drag DropShelf to `/Applications`. The app is not notarized, so on first launch right-click it and choose Open, or allow it under System Settings › Privacy & Security.

## Updates

The app will be able to notify you about new releases (coming soon).

## Build from source

```sh
xcodegen
xcodebuild -project DropShelf.xcodeproj -scheme DropShelf -configuration Release -derivedDataPath build build
```

The app ends up in `build/Build/Products/Release/DropShelf.app`. For launch at login to work reliably, copy it to `/Applications`. The icon can be regenerated with `swift scripts/make-icon.swift`.

The "Troll" build variants use a bundled sound and image that are not included in this repository, so those targets do not build from a clone.

## Permissions

- **Accessibility**: only for shake detection (it reads mouse movement only). Everything else works without it.
- Keyboard shortcuts need no permission.

## Sandbox

DropShelf runs in the App Sandbox. File access goes through files the user dropped and security-scoped bookmarks, so shelves survive a restart. There is no network access and there are no third-party libraries.

## License

Source-available under the [PolyForm Noncommercial License 1.0.0](LICENSE). Free for personal and other noncommercial use. Commercial use is not permitted.

© 2026 Lennet Schierhorn (Horn2208)
