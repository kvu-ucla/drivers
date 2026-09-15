# Sony Camera HTTP CGI Protocol (UCLA)

**Version:** 2.0.1 — the UCLA-maintained line diverging from upstream.

> UCLA-maintained copy of `drivers/sony/camera/cgi_protocol.cr` (vendored 2026-08-30 from ucla-dev @ ce19af2a18).

## Overview

Controls Sony PTZ cameras over the HTTP CGI command protocol with digest authentication (per the Sony camera CGI commands documentation). Provides pan/tilt/zoom/focus absolute positioning, 8-way and joystick relative movement, camera-side and driver-side presets, autoframing, and power/standby. PTZF state is polled every 60 seconds plus a configurable minutes-based schedule. Implements `Interface::Camera` and `Interface::DeviceInfo`; identity comes from the `inq=system` inquiry with graceful degradation (fields go nil when the inquiry fails, model never empty). Generic name `Camera`.

## Settings

| Key | Type | Default | Description |
|---|---|---|---|
| `digest_auth` | Object | `{username: "admin", password: "Admin_1234"}` | Digest credentials. |
| `invert_controls` | Bool | `false` | Inverts vertical movement (ceiling mounts). |
| `presets` | Hash | `{name: {pan: 1, tilt: 1, zoom: 1}}` | Named PTZF presets; managed via `save_position`/`remove_position` (stored back to settings). |
| `enable_debug_logging` | Bool | `false` | Extra digest-auth debug logging. |
| `poll_interval_in_minutes` | Int32 | `5` | Additional recurring `query_status` schedule. |

## Status keys

| Key | Description |
|---|---|
| `pan` / `tilt` / `zoom` / `focus` | Current position (`zoom` as 0–100 percentage, `focus` raw). |
| `pan_range` / `tilt_range` / `zoom_range` | Movement ranges reported by the camera. |
| `pan_speed` / `tilt_speed` | Speed range constants `{min: -100, max: 100, stop: 0}`. |
| `has_discrete_zoom` | Always true. |
| `moving` / `zooming` | Motion state. |
| `presets` | Configured preset names. |
| `invert_controls` | Current inversion setting. |
| `autoframe` | Autoframing state. |
| `power` | Power state (from the `sysinfo` inquiry). |
| `model_name` / `serial` / `soft_version` / `model_form` / `cgi_version` | Legacy identity keys, published from the `device_info` system inquiry. |
| `device_info` | Common descriptor published by the DeviceInfo interface. |

## Exec methods

| Method | Arguments | Description / returns |
|---|---|---|
| `query_status` | `priority : Int32 = 0` | PTZF inquiry (also polls autoframing and power); returns the PTZF task so `exec(...).get` resolves with PTZ state. |
| `info?` | - | Manual `inq=system` identity inquiry (publishes the legacy identity keys). |
| `device_info` | - | Descriptor from a direct system inquiry: make `Sony`, `ModelName` with `Camera` fallback, serial, firmware (`SoftVersion`), MAC, configured host. Also republishes the legacy identity keys. |
| `move` | `position : String` - `Up`/`Down`/`Left`/`Right` (4-way), `In`/`Out` (zoom); `index : Int32 \| String = 0` - camera index, 1-based | Directional movement. |
| `move_all` | `position : String` - `Up`, `Down`, `Left`, `Right`, `UpLeft`, `UpRight`, `DownLeft`, `DownRight`, `Tele`, `Wide`; `index : Int32 \| String = 0` | 8-way + Tele/Wide movement. |
| `joystick` | `pan_speed : Float64` - −100…100; `tilt_speed : Float64` - −100…100; `index : Int32 \| String = 0` | Proportional movement; `0`/`0` stops. |
| `stop` | `index : Int32 \| String = 0` - camera index; `emergency : Bool = false` - clears the queue | Stop motion. |
| `stop_zoom` | - | Stop zoom. |
| `pantilt` | `pan : Int32`; `tilt : Int32`; `zoom : Int32? = nil`; `focus : Int32? = nil` - values clamped to reported ranges | Absolute positioning. |
| `zoom` | `direction : String` - `In`/`Out`/`Stop`; `index : Int32 \| String = 0` | Relative zoom. |
| `zoom_to` | `position : Float64` - 0–100 %; `auto_focus : Bool = true`; `index : Int32 \| String = 0` | Absolute zoom (0–100 %). |
| `home` | - | Recalls the camera home position. |
| `recall` | `position : String` - preset name; `index : Int32 \| String = 0` | Recalls a driver-side preset. |
| `save_position` | `name : String`; `index : Int32 \| String = 0` | Saves a driver-side preset (persisted to settings). |
| `remove_position` | `name : String`; `index : Int32 \| String = 0` | Removes a driver-side preset. |
| `cam_preset_save` / `cam_preset_recall` | `preset_no : Int32` | Camera-side presets. |
| `autoframe` | `state : Bool` - `true` on / `false` off | PTZ autoframing control. |
| `autoframing?` | - | Queries autoframing state. |
| `power` | `state : Bool` - `true` on / `false` standby | On/standby control. |
| `power?` | - | Queries power state. |

## 2.0.1 (2026-09-08)

- Documentation: Exec methods table now states argument types, allowed values, and defaults (no code change).

## 2.0.1 (2026-09-10)

- Fixes a Crystal 1.19.1 codegen crash (`Cast from Nil to ProcInstanceType`) that broke compilation in HTTP-only builds (the PlaceOS build service configuration). Two changes: the `action` command helper no longer forwards its block's incidental result as the task payload (command exec results now resolve with null payloads — previously undefined garbage), and the `query` helper casts its forwarded block result to an explicit union (`Hash(String, String) | Bool | Nil`) — payloads unchanged, the cast alone defeats the compiler bug. The upstream driver carries the same defect.

## 2.0.0 (2026-08-31)

- Vendored from ucla-dev @ ce19af2a18 with DeviceInfo support.
- `inq=system` identity mapped with graceful degradation: any inquiry failure returns partial info with nil fields, and the model uses a presence fallback (`Camera`) so it is never empty.
- `query_status` now returns the PTZF task so `exec(:query_status).get` resolves with PTZ state instead of a dangling `power?` task (exec awaits a returned Task — the old last-expression `power?` held callers hostage to an unanswered `sysinfo` inquiry).
- The DeviceInfo interface owns the identity cadence: the scheduled `info?` was removed from `on_load`; the legacy identity statuses (`model_name`, `serial`, `soft_version`, `model_form`, `cgi_version`) are published from the interface's own fetch. `info?` remains as a manual method.
- Spec drains trailing enquiries — fixing a latent 8-minute stall at the end of the run — and adds `device_info` coverage.

## Pre-2.0 (upstream history)

- Upstream `cgi_protocol.cr` as of ucla-dev @ ce19af2a18: the full PTZF/preset/autoframing/power control surface above with digest-auth challenge handling and 502/401 recovery.

## Known issues / residuals

- **Pre-existing default-settings gotcha (accepted):** the `presets` setting is parsed as `{pan, tilt, zoom, focus}`, but the shipped default omits `focus`, so `on_load` logs a `JSON::ParseException` and presets default to empty until the setting is corrected. Harmless; untouched.
