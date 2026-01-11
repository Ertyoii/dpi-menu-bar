# DpiMenuBar

Menu bar app for inspecting and setting Logitech mouse DPI via HID++ over USB or Bluetooth.

## Features

- Lists connected Logitech devices that expose HID++ DPI features.
- Shows current DPI and available presets.
- Adjusts DPI from the macOS menu bar.
- Remembers your last selected device and DPI.

## Requirements

- macOS 13 or later
- Swift 5.9+ (Xcode 15+)

## Build

```sh
swift build
```

## Run

```sh
./.build/debug/DpiMenuBar
```

The app appears as a menu bar icon labeled "DPI".

## Usage

1. Click the menu bar icon.
2. Pick your mouse from the "Mouse" menu.
3. If DPI control is available, adjust the slider.
4. Use "Refresh" if devices are added or removed.

## Permissions

No special macOS entitlements are required for HID++ access in this project.
If you package the app (e.g. notarized .app), ensure the sandbox is disabled or
HID access will fail.

## Troubleshooting

- "DPI control not available": The device may not expose HID++ DPI features.
- "DPI feature not found": The device is detected but doesn't support DPI control.
- "DPI update failed": Try reconnecting the device or click "Refresh".

If the device becomes locked (exclusive access), quit the app and reconnect the mouse.

## Development Notes

- HID++ communication is implemented in `Sources/DpiMenuBar/HIDPPDevice.swift`.
- Device discovery is handled by `Sources/DpiMenuBar/HIDPPManager.swift`.
- UI lives in `Sources/DpiMenuBar/DpiMenuBarApp.swift`.
