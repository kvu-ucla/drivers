# Sony Camera HTTP CGI Protocol (UCLA)

**Version:** 2.0.0 — the UCLA-maintained line diverging from upstream.

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

| Method | Description |
|---|---|
| `query_status(priority)` | PTZF inquiry (also polls autoframing and power); returns the PTZF task so `exec(...).get` resolves with PTZ state. |
| `info?` | Manual `inq=system` identity inquiry (publishes the legacy identity keys). |
| `device_info` | Descriptor from a direct system inquiry: make `Sony`, `ModelName` with `Camera` fallback, serial, firmware (`SoftVersion`), MAC, configured host. Also republishes the legacy identity keys. |
| `move(position, index)` / `move_all(position, index)` | Directional movement (4-way interface / 8-way + Tele/Wide). |
| `joystick(pan_speed, tilt_speed, index)` | Proportional movement, speeds −100..100. |
| `stop(index, emergency)` / `stop_zoom` | Stop motion / stop zoom. |
| `pantilt(pan, tilt, zoom, focus)` | Absolute positioning (values clamped to reported ranges). |
| `zoom(direction, index)` / `zoom_to(position, auto_focus, index)` | Relative / absolute (0–100 %) zoom. |
| `home` | Recalls the camera home position. |
| `recall(position, index)` / `save_position(name, index)` / `remove_position(name, index)` | Driver-side presets (persisted to settings). |
| `cam_preset_save(preset_no)` / `cam_preset_recall(preset_no)` | Camera-side presets. |
| `autoframe(state)` / `autoframing?` | PTZ autoframing control/query. |
| `power(state)` / `power?` | On/standby control and query. |

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
