# Sony Bravia LCD Display (UCLA)

**Version:** 2.0.0 — the UCLA-maintained line diverging from upstream.

> UCLA-maintained copy of `drivers/sony/displays/bravia.cr` (vendored 2026-08-30 from ucla-dev fork @ ca4750ac07). Based on the production pin — the commit production actually runs; repo HEAD had drifted 9 unvetted upstream commits ahead of it.

## Overview

Controls Sony Bravia displays over the Simple IP control protocol (raw TCP, port 20060, `*S`-prefixed 24-byte frames). Provides power, input selection, picture/audio mute and volume, with a 30-second status poll while the display is on. Implements `Interface::Powerable`, `Interface::Muteable`, `Interface::InputSelection` and `Interface::DeviceInfo` — the descriptor is a pure cache read (make `Sony`, static model `Bravia`, cached MAC, configured IP); a one-time MAC enquiry is issued at connect and cached via the normal response path. Generic name `Display`.

## Settings

None — the driver reads no settings. Connection details come from the module's transport configuration (IP/port).

## Status keys

| Key | Description |
|---|---|
| `power` | Display power state. |
| `input` | Current input (`Tv0`–`Tv3`, `Hdmi0`–`Hdmi3`, `Mirror0`–`Mirror3`, `Vga0`–`Vga3`). |
| `volume` | Current volume (0–100). |
| `volume_min` / `volume_max` | Constants `0` / `100`. |
| `mute` | Picture mute state. |
| `audio_mute` | Audio mute state. |
| `pip` | Picture-in-picture state (from notifications). |
| `mac_address` | Cached MAC from the connect-time `MADR` enquiry. |
| `device_info` | Common descriptor published by the DeviceInfo interface. |

## Exec methods

| Method | Description |
|---|---|
| `power(state)` / `power?` | Power control and query. |
| `switch_to(input)` / `input?` | Input selection and query. |
| `mute(state, index, layer)` / `unmute` / `mute?` | Picture mute. |
| `mute_audio(state)` / `unmute_audio` / `audio_mute?` | Audio mute. |
| `volume(level)` / `volume?` / `volume_up` / `volume_down` | Volume (clamped 0–100; up/down step by 5). |
| `mac_address?` | `MADR` enquiry — the interface name `eth0` right-padded with `#` to 16 bytes, as the protocol requires. |
| `do_poll` | Polls input/mute/audio-mute/volume when the display is on. |
| `device_info` | Pure cache read of the descriptor (no protocol traffic). |

## 2.0.0 (2026-08-31)

- Re-vendored onto the production pin `ucla-dev fork @ ca4750ac07` (an earlier vendoring from repo HEAD was discarded — HEAD carried 9 unvetted upstream commits not running in production).
- Added `Interface::DeviceInfo` as a cache-only descriptor: a correctly formed `MADR` enquiry (`eth0` padded to 16 bytes — the getMacAddress enquiry requires the interface name, unlike the generic all-`#` form) is issued once at connect and cached by the normal response handling; `device_info` performs no I/O. Model is the static `Bravia`, IP from configuration.
- Spec covers the connect-time MAC exchange and the cache read; the full spec passes against the pinned base.

## Pre-2.0 (upstream history)

- The pinned production base predates several upstream HEAD changes: no `force_targets` power/input target enforcement, the older `Answer` response handling (no per-command success/abort split), and `do_poll` without a leading `power?.get`.

## Known issues / residuals

- Simple IP control exposes no model/serial/firmware enquiries — those descriptor fields are nil by design, nothing is invented.
- `device_info` calls made before the connect-time MAC enquiry is answered report a nil `mac_address`; it appears from the next publish onward.
