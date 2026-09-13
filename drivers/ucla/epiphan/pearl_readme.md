# Epiphan Pearl Recording Device (UCLA)

**Version:** 2.0.1 — the UCLA-maintained line diverging from upstream.

> UCLA-maintained copy of `drivers/epiphan/pearl.cr` (vendored 2026-08-30 from ucla-dev @ ce19af2a18).

## Overview

Controls Epiphan Pearl-2 and Pearl Mini recording/streaming devices over their HTTPS REST API v2.0 with basic authentication. Covers recording control (start/stop/pause/resume), streaming control for channel publishers, channel layout switching, and active recording/streaming monitoring, with a recurring status poll (default every 30 seconds). Implements `Interface::DeviceInfo`: the descriptor is built from the firmware endpoint (make `Epiphan`, product name as model, firmware version) and degrades gracefully — the REST API exposes no serial/MAC, so those fields are nil, never fabricated. Generic name `Recording`.

## Settings

| Key | Type | Default | Description |
|---|---|---|---|
| `basic_auth` | Object | `{username: "admin", password: "admin"}` | Device admin credentials. |
| `poll_every` | Int32 | `30` | Status poll interval in seconds. |
| `camera_map` | Hash(String, String) | `{}` | Optional camera-name map, republished as the `camera_map` status. |

## Status keys

| Key | Description |
|---|---|
| `firmware` | Firmware details from `/api/v2.0/system/firmware` (published by `get_firmware`, called via `device_info`). |
| `connectivity_details` | Result of the connectivity check run shortly after connect. |
| `system_status` | Device system status (polled). |
| `recorders` / `channels` | Configured recorders and channels (polled). |
| `recorder_<id>_status` | Per-recorder status. |
| `channel_<id>_layouts` / `channel_<id>_publishers` | Per-channel layouts and publishers. |
| `active_recordings` / `number_of_active_recordings` | Recorder IDs currently recording, and the count. |
| `active_streamings` | `{channel_id, publisher_ids}` entries currently streaming. |
| `<input_id>_video_status` | True when the input's video is active with a valid FPS. |
| `camera_map` | The configured camera map. |
| `device_info` | Common descriptor published by the DeviceInfo interface. |

## Exec methods

| Method | Arguments | Description / returns |
|---|---|---|
| `start_recording` / `stop_recording` | `recorder_id : String` | Recording control (status re-queried 2 s later). |
| `pause_recording` / `resume_recording` | `recorder_id : String` | Pause/resume. |
| `stop_all_recordings` | — | Stops every active recorder; returns per-recorder success. |
| `is_recording?` | `recorder_id : String` | Returns `Bool` — `true` when the recorder state is `Started`. |
| `get_active_recordings` / `list_recorders` | — | Recorder queries. |
| `get_recorder_status` | `recorder_id : String` | Returns the recorder status. |
| `start_streaming` / `stop_streaming` | `channel_id : String`; `publisher_id : String` | Publisher control. |
| `is_streaming?` | `channel_id : String` | Returns `Bool` — `true` when the channel has an active streaming publisher. |
| `get_active_streamings` | — | Returns `{channel_id, publisher_ids}` entries currently streaming. |
| `list_publishers` | `channel_id : String` | Lists the channel's publishers. |
| `list_channels` | — | Lists configured channels. |
| `get_channel_layouts` | `channel_id : String` | Lists the channel's layouts. |
| `set_channel_layout` | `channel_id : String`; `layout_id : String` | Applies a layout; re-queries layouts 2 s later. Returns `true`. |
| `get_system_status` | — | Device system status. |
| `get_inputs_status` | `type : String? = nil` — optional `?types=` filter | Input status; publishes `<input_id>_video_status`. |
| `get_connectivity_details` | — | Connectivity check result. |
| `get_firmware` | — | Firmware details (publishes `firmware`). |
| `device_info` | — | Returns the `Descriptor` (firmware fetch with rescued degradation). |
| `init_camera_map` | — | Re-reads the `camera_map` setting. |

## 2.0.1 (2026-09-08)

- Documentation: Exec methods table now states argument types and return types (no code change).

## 2.0.0 (2026-08-31)

- Vendored from ucla-dev @ ce19af2a18 with DeviceInfo support.
- Descriptor built from the firmware endpoint with a presence-checked model fallback (`Pearl` when the reported product name is empty) and rescued degradation to nil fields when the query fails.
- Pearl's own poll tasks are now tracked handles (`schedule_status_polling` cancels and recreates only its own polls) — previously `on_update` ran a global `schedule.clear` that also cancelled the DeviceInfo interface's schedules.
- Identity cadence is interface-owned: the connect-time firmware fetch was removed; firmware/identity acquisition (and the legacy `firmware` status) comes from the interface-driven `device_info` → `get_firmware` call.
- Spec adds `device_info` coverage; the full spec passes.

## Pre-2.0 (upstream history)

- Upstream `pearl.cr` as of ucla-dev @ ce19af2a18: full REST API v2.0 recording/streaming/layout control and status polling as described above.
