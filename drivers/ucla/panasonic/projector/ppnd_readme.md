# Panasonic Projector PPND API (UCLA)

**Version:** 2.0.0 — the UCLA-maintained line diverging from upstream.

> UCLA-maintained copy of `drivers/panasonic/projector/ppnd.cr` (vendored 2026-08-30 from ucla-dev @ ce19af2a18).

## Overview

Controls Panasonic projectors via the PPND WEB API (`https://<host>/api/v1/`, JSON over HTTP/HTTPS with digest authentication). Implements `Interface::Powerable`, `Interface::Muteable` (AV shutter), `Interface::InputSelection` and `Interface::DeviceInfo`. Power and input commands record a target and the recurring status poll (default every 30 seconds) re-issues the command until the device reports the requested state. Identity is queried once on settings load; `device_info` serves it from cached status keys. Generic name `Display`.

## Settings

| Key | Type | Default | Description |
|---|---|---|---|
| `digest_auth` | Object | `{username: "admin", password: "panasonic"}` | Digest credentials. |
| `api_version` | String | `"v1"` | API version segment in request paths. |
| `poll_interval` | Int32 | `30` | Status poll interval in seconds. |
| `enable_https` | Bool | `true` | Declared in `default_settings` but not read by the driver logic (transport scheme comes from the module URI). |

## Status keys

| Key | Description |
|---|---|
| `power` | Projector power state. |
| `input` | Current input (mapped to the `Input` enum names). |
| `av_mute` | Shutter state. |
| `freeze` | Image freeze state (query/command only when powered). |
| `signal_info` / `no_signal` | Current signal description; `no_signal` true when the device reports `NO SIGNAL`. Updated only by explicit `query_signal` calls (not polled). |
| `errors` / `error_count` / `has_errors` | Active device errors (filtered of `no error` entries). |
| `lights` / `lamp_usage` | Light-source status; `lamp_usage` is the first light's runtime. |
| `temperatures` | Sensor temperatures. |
| `model` / `serial_number` / `projector_name` / `mac_address` | Identity from `/device-information` (queried on settings load). |
| `firmware_version` | Main firmware version (via `query_firmware_version`). |
| `ntp_sync` / `ntp_server` / `https_enabled` | Network configuration state. |
| `device_info` | Common descriptor published by the DeviceInfo interface. |

## Exec methods

| Method | Description |
|---|---|
| `power(state)` / `power?` / `query_power_status` | Power control with target re-assertion. |
| `switch_to(input)` | Inputs: `COMPUTER`, `HDMI` (maps to HDMI1), `HDMI1`, `HDMI2`, `MemoryViewer`, `Network`, `DigitalLink`. (See Known issues: the intended unmute-before-switch never triggers.) |
| `query_input_status` | Re-reads the input (re-asserts a pending target). |
| `mute(state, index, layer)` / `query_av_mute_status` | AV shutter control. |
| `freeze(state)` / `query_freeze_status` | Image freeze (projector must be on). |
| `query_errors` / `query_lights` / `query_temperatures` | Status queries (also run by the 30-second poll, alongside power/input/av-mute). |
| `query_signal` | On-demand signal query — **not** part of the recurring poll; `signal_info`/`no_signal` only update when this is called explicitly. |
| `query_device_info` / `query_firmware_version` | Identity queries. |
| `query_operating_mode` / `operating_mode(mode)` | Operating mode (`Normal`, `Eco`, `Quiet`, `User1`–`User3`). |
| `query_device_schedule` | Device schedule. |
| `configure_ntp(sync, server)` / `query_ntp_settings` | NTP configuration. |
| `configure_https(enabled)` / `query_https_config` | HTTPS configuration. |
| `device_info` | Descriptor from cached identity: make `Panasonic`, model with `Projector` fallback, serial, MAC, configured host, projector name as hostname. |

## 2.0.0 (2026-08-31)

- Vendored from ucla-dev @ ce19af2a18 — the driver already conformed to the DeviceInfo cache-read pattern — then hardened:
- `on_update` now replaces only the projector's own tracked poll task; the previous global `schedule.clear` also cancelled the DeviceInfo interface's schedules on every settings change.
- Descriptor gained `ip_address` (configured host) and a presence-checked `Projector` model fallback (an empty reported model also falls back) instead of `Unknown`.

## Pre-2.0 (upstream history)

- Upstream `ppnd.cr` as of ucla-dev @ ce19af2a18: PPND WEB API control surface as described above, including power/input target re-assertion (API change noted in source: version 2.99 → 3.00).

## Known issues / residuals

- **Unmute-before-switch never triggers (driver defect, future fix):** `switch_to` intends to open the shutter before switching, but it tests `self[:mute]?` (`ppnd.cr:257`) while the shutter command/query paths publish feedback only as `av_mute` (`ppnd.cr:298-323`) — the driver never recognises its own reported shutter state, so no `/av-mute` off command is sent and a shuttered projector stays dark after an input switch. Correcting the driver to test `av_mute` is future work; unmute explicitly via `mute(false)` in the meantime.
- **Pre-existing red baseline spec (accepted):** the module never connects under the spec harness because `on_load → on_update → query_device_info` blocks on an HTTP request the spec never services. The failure predates and is untouched by the UCLA changes (log signatures identical to baseline); fixing it needs spec surgery.
