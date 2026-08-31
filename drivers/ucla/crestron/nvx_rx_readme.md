# Crestron NVX Receiver (UCLA)

**Version:** 2.0.0 — the UCLA-maintained line diverging from upstream.

> UCLA-maintained copy of `drivers/crestron/nvx_rx.cr` (vendored 2026-08-30 from ucla-dev @ ce19af2a18). Built on the shared UCLA `cres_next.cr` / `cres_next_auth.cr` base.

## Overview

Controls a Crestron DM NVX decoder. Transport is a secure websocket (`wss://<host>/websockify`) for state queries and pushed updates, plus HTTPS POSTs for configuration changes and session login (cookie auth with a `CREST-XSRF-TOKEN` header). Implements `Interface::Switchable(String, Int32)`, `Interface::InputSelection(String)`, `Interface::StandbyImage`, the `Crestron::Receiver` marker module, and `Interface::DeviceInfo` via the shared CresNext base. Generic name `Decoder`.

Routing to a transmitter is done by POSTing the transmitter's advertised RTSP URI into `/StreamReceive/Streams` (`switch_stream_location`) — no `/AvRouting/Routes` UUID writes on that path. The legacy Xio-subscription switching machinery is still present but dormant (see residuals). The shared CresNext base behaviour (10-minute failure-isolated session keep-alive, infallible cached `device_info` with `DeviceVersion` firmware) is described in `nvx_tx_readme.md`.

## Settings

| Key | Type | Default | Description |
|---|---|---|---|
| `username` | String | `"admin"` | Device login. |
| `password` | String | `"admin"` | Device login password. |
| `audio_follows_video` | Bool | `true` | When true, audio source is set to `AudioFollowsVideo` on switches; when false, audio is switched explicitly. Re-read on settings update without re-auth. |

## Status keys

| Key | Description |
|---|---|
| `stream_location` | RTSP URI currently routed into `/StreamReceive/Streams` (nil when no stream). Updated by queries and by out-of-band pushed deltas. |
| `stream_status` | Received-stream `Status`. |
| `subscriptions` | Registered Xio subscriptions (legacy index-based switching). |
| `device_name` | Device localisation name. |
| `osd_text` | Current on-screen-display text. |
| `video_source` / `audio_source` | Active source names (streams reported as `Stream-<uuid>`). |
| `<input>_sync` | Sync state per input, keyed by the device's `UserSpecifiedName` (lowercased, spaces removed); true when a port reports vertical resolution ≥ 1080. |
| `authenticated` / `auth_error` | Session state published by the shared auth module. |
| `device_info` | Common descriptor published by the DeviceInfo interface. |
| `WARN` | Set when the hardware is configured as a Transmitter instead of a Receiver. |

## Exec methods

| Method | Description |
|---|---|
| `switch_to(input)` | Name-based switch: `none`/`break`/`clear`/`blank`/`black` blank the output; `input1`/`hdmi`/`hdmi1`, `input2`/`hdmi2`, `input3`/`usbc1`, `input4`/`usbc2` select local inputs; inputs starting with `rtsp` route via `switch_stream_location`; anything else falls through to the dormant Xio path. |
| `switch_stream_location(location)` | Routes a transmitter's advertised stream: rejects empty URIs, POSTs `[{StreamLocation: uri}]` to `/StreamReceive/Streams` (raises loudly if the device rejects the write), then sets `VideoSource = "Stream"` and audio per `audio_follows_video`. |
| `switch(map, layer)` | Switchable-interface entry point (uses the first input in the map). |
| `output(state)` | Enables/disables HDMI output sync. |
| `output_with_index(state, output_index, port_index)` | Per-output/port variant of `output`. |
| `aspect_ratio(mode)` | `MaintainAspectRatio` or `StretchToFit`. |
| `set_osd_text(text, enabled)` / `query_osd_text` | OSD control. |
| `enable_background_image(state, output_index)` | Enables the standby image (Support level). |
| `set_background_image(url, output_index)` | Downloads the image and uploads it to the decoder's local image slot, then points the output at it (Administrator level). |
| `set_background_image_name(image_name, output_index)` | Selects an already-uploaded local image (Administrator level). |
| `device_info` | Fetches/serves the descriptor (shared base). |
| `authenticate` / `logout` / `maintain_session` | Session management (shared auth module). |
| `manual_send(payload)` | Raw websocket payload (Support level). |
| `reboot(now)` | Reboots the device (Administrator level). |
| `__stat_mem__` / `__stat_fiber__` | Driver memory / fiber diagnostics. |

## 2.0.0 (2026-08-31)

- Vendored as an unchanged copy of `drivers/crestron/nvx_rx.cr` + spec from ucla-dev @ ce19af2a18.
- Shared CresNext base DeviceInfo hardening (see `nvx_tx_readme.md` for the full list): infallible cached `device_info`, `DeviceVersion` firmware, failure-isolated session keep-alive with pre-response failures still publishing `authenticated`/`auth_error`.
- StreamLocation routing: new `switch_stream_location(uri)` — rejects blank URIs, POSTs `StreamLocation` to `/StreamReceive/Streams` and **fails loudly when the device rejects the write** (previously `Task#get` returned rather than raised on an aborted task, so device rejections were silently swallowed and the switch sequence continued), then sets `VideoSource = "Stream"` with audio per `audio_follows_video`; no `/AvRouting/Routes` UUID writes in this path. Publishes `stream_location`/`stream_status` including out-of-band pushed deltas. `switch_to` routes `rtsp…` inputs through this path; `audio_follows_video` is now refreshed in `on_update` so settings changes apply without re-auth.
- Spec covers the full write sequence, both audio variants, non-2xx device rejection (proving no source writes follow a rejection), out-of-band pushes, and the blank path.

## Pre-2.0 (upstream history)

- Upstream `nvx_rx.cr` as of ucla-dev @ ce19af2a18: Xio-subscription UUID switching, local input selection, OSD and background-image handling, Avio input-sync processing, and recurring polls registered in `connected` so re-auth cannot leak schedules.

## Known issues / residuals

- **Pre-existing red spec section (accepted):** the background-image case expects the `HostBackgroundImage` write within a 500 ms `should_send`, but the driver issues it from a `schedule.in(40.seconds)` — the spec times out there. The failure predates the UCLA changes and its signature is unchanged; fixing it needs spec surgery.
- **Xio machinery dormant, not deleted:** a `switch_to` with a non-rtsp, non-local input name still reaches the legacy `switch_stream` Xio path (subscriptions are still queried hourly). Removal is a later pass.
