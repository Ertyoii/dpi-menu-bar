# HID++ Notes

This project implements a small slice of Logitech HID++ 2.0 over the macOS
HID stack (IOKit). The goal is DPI read/write for supported mice and receivers.
There is no official public HID++ spec from Logitech; these notes come from
observed behavior and public reverse engineering.

## Device Discovery

- IOHIDManager matches Logitech vendor ID `0x046d`.
- Usage page is Generic Desktop and usage is Mouse or Pointer.

## Report IDs and Payloads

- HID++ short report ID: `0x10`
- HID++ long report ID: `0x11`
- We try output report type first, then feature report type if needed.
- Payload lengths:
  - short: 5 bytes of data
  - long: 18 bytes of data
- The device number byte is prepended to the payload. We attempt:
  - `0x00` (receiver/channel)
  - `0xFF` (direct device fallback, common on Bluetooth)

### Frame Layout (as used in this app)

Short report (ID `0x10`, 5 data bytes):

```
Byte:  0     1        2        3        4        5        6
Field: RID   DEV      REQ_HI   REQ_LO   P0       P1       P2
```

Long report (ID `0x11`, 18 data bytes):

```
Byte:  0     1        2        3        4..21
Field: RID   DEV      REQ_HI   REQ_LO   P0..P17
```

Notes:

- `REQ_LO` includes the 4-bit software ID (low nibble).
- On responses, the first byte after `DEV` and `REQ_HI/REQ_LO` is the payload.

## Request Format and Matching

- HID++ request ID is 16 bits: `featureIndex << 8 | (function & 0xF0)`.
- We set a 4-bit "software ID" in the low nibble to match responses.
- Requests are sent with `IOHIDDeviceSetReport` and responses arrive via the
  input report callback.
- Error replies are detected by `data[1] == 0xFF`, with the error code in
  `data[4]`.

### Response Error Frame (observed)

```
data[0] = device number
data[1] = 0xFF
data[2] = REQ_HI
data[3] = REQ_LO
data[4] = error code
```

### Basic Request/Response Flow

```
App -> IOHIDDeviceSetReport -> Device
App stores continuation keyed by (REQ_HI, REQ_LO)

Device -> input report callback -> App
App matches REQ_HI/REQ_LO and resumes continuation
```

## Feature Discovery

To discover a feature index, send request `0x0000` with params
`[featureID_hi, featureID_lo]`. The response first byte is the feature index.

Relevant feature IDs:

- `0x2202` EXTENDED_ADJUSTABLE_DPI
- `0x2201` ADJUSTABLE_DPI

## DPI Functions Used

For ADJUSTABLE_DPI (0x2201):

- `0x10` list
- `0x20` get
- `0x30` set

For EXTENDED_ADJUSTABLE_DPI (0x2202):

- `0x10` capabilities
- `0x20` list
- `0x50` get
- `0x60` set

## DPI List Encoding

Lists are returned as 16-bit values (big endian). The list ends with `0x0000`.

If the top three bits are `0b111`, the value encodes a step range:

- lower 13 bits = step size
- next 16-bit value = last DPI
- the range expands from the previous value by `step` until `last`

This parsing logic is implemented in `Sources/DpiMenuBar/DpiListParser.swift`
with unit tests in `Tests/DpiMenuBarTests/DpiListParserTests.swift`.

## DPI Get/Set Sequence (Simplified)

```
open device
  -> request feature index (0x0000 + featureID)
  -> read list (function 0x10 or 0x20)
  -> read current (function 0x20 or 0x50)
set new dpi
  -> set value (function 0x30 or 0x60)
  -> read current (same as above)
```

## Scheduling and Lifecycle

- The HID device is scheduled on the main run loop so callbacks arrive on the
  same loop as the manager.
- Devices are opened with `kIOHIDOptionsTypeNone` and must be closed promptly.
  Leaving a device open can trigger `kIOReturnExclusiveAccess` errors elsewhere.

## Caveats

- Not all Logitech devices expose these features.
- Some devices report empty lists or require fallback device numbers.
- Behavior can vary across transport (USB receiver vs Bluetooth).

## References (Reverse Engineering)

These are commonly used public sources for HID++ behavior and feature IDs:

- Solaar project (HID++ tooling and docs): https://github.com/pwr-Solaar/Solaar
- libratbag project (HID++ implementation for devices): https://github.com/libratbag/libratbag
- Linux kernel HID++ driver: https://github.com/torvalds/linux/blob/master/drivers/hid/hid-logitech-hidpp.c
