# Crestron NVX Transmitter (UCLA)

**Version:** 2.0.0 — the UCLA-maintained line diverging from upstream.

> UCLA-maintained copy of `drivers/crestron/nvx_tx.cr` (vendored 2026-08-30 from ucla-dev @ ce19af2a18). Built on the shared UCLA `cres_next.cr` / `cres_next_auth.cr` base.

## Overview

Controls a Crestron DM NVX encoder. Transport is a secure websocket (`wss://<host>/websockify`) for state queries and pushed updates, plus HTTPS POSTs for configuration changes and session login (cookie auth with a `CREST-XSRF-TOKEN` header). Implements `Interface::InputSelection(Input)` (inputs `None`, `Input1`, `Input2`), the `Crestron::Transmitter` marker module, and `Interface::DeviceInfo` via the shared CresNext base. Generic name `Encoder`.

The driver publishes the stream advertisement (`stream_location`, the RTSP URI) that receivers and the UCLA virtual switcher use for StreamLocation-based routing.

### Shared CresNext base behaviour

- On connect, re-arms a 10-minute session keep-alive (`maintain_session`) that refreshes the login cookies. The refresh is failure-isolated: a transient HTTP/auth failure is logged and retried on the next tick — it never drives `disconnected`/`schedule.clear` on a still-open websocket.
- `device_info` fetches `/Device/DeviceInfo` over HTTPS and is infallible: on failure it serves the last good descriptor or an honest static fallback (make `Crestron`, model `NVX`, configured host). Firmware reports the device's `DeviceVersion` (with labelled `puf` and `built` values), not the payload's schema `Version`.

## Settings

| Key | Type | Default | Description |
|---|---|---|---|
| `username` | String | — (required) | Device login, read by the shared `authenticate`. |
| `password` | String | — (required) | Device login password. |

## Status keys

| Key | Description |
|---|---|
| `stream_location` | Advertised RTSP URI from `/StreamTransmit/Streams` (nil when empty). |
| `stream_status` | Stream `Status` from the same object. |
| `multicast_address` | Current multicast address of the stream. |
| `nax_address` | AES67 (NAX) audio session name, used for audio-sink routing. |
| `stream_name` | Device localisation name. |
| `video_source` / `audio_source` | Active source names from `/DeviceSpecific/Active{Video,Audio}Source`. |
| `input_<n>_sync` | Sync detected on HDMI input *n* (from pushed `AudioVideoInputOutput` updates). |
| `authenticated` / `auth_error` | Session state published by the shared auth module. |
| `device_info` | Common descriptor published by the DeviceInfo interface. |
| `WARN` | Set when the hardware is configured as a Receiver instead of a Transmitter. |

## Exec methods

| Method | Description |
|---|---|
| `switch_to(input)` | Selects the local video input (`None`/`Input1`/`Input2`), audio follows video. |
| `output(state)` | Enables/disables HDMI output sync. |
| `multicast_address(address)` | Sets the stream multicast address. |
| `stream_start` / `stream_stop` | POSTs `[{Start: true}]` / `[{Stop: true}]` to `/StreamTransmit/Streams`. |
| `emulate_input_sync(state, idx)` | Manually sets `input_<idx>_sync` (testing aid). |
| `device_info` | Fetches/serves the descriptor (see base behaviour above). |
| `maintain_session` | Failure-isolated login refresh (also on a 10-minute schedule). |
| `authenticate` / `logout` | Session management (shared auth module). |
| `manual_send(payload)` | Sends a raw websocket payload (Support level). |
| `reboot(now)` | Reboots the device (Administrator level). |

## 2.0.0 (2026-08-31)

- Vendored as an unchanged copy of `drivers/crestron/nvx_tx.cr` + spec from ucla-dev @ ce19af2a18.
- Shared CresNext base hardened for DeviceInfo: infallible `device_info` (cached descriptor or honest static fallback), firmware reads `DeviceVersion` rather than the schema `Version` with an `NVX` model fallback, and the 10-minute session keep-alive was decoupled from device-info queries — `authenticate` gained a `lifecycle` flag so a transient refresh failure never calls `set_connected(false)`/`schedule.clear`, while pre-response failures (timeout, refusal, TLS) still publish `authenticated = false` and `auth_error` before re-raising.
- StreamLocation routing support: publishes `stream_location` (nil when empty) and `stream_status` from `/StreamTransmit/Streams` alongside the existing `multicast_address`; parses pushed `StreamTransmit` deltas in `received`; adds `stream_start`/`stream_stop`. Property names and writability verified against the Crestron DM NVX REST API documentation.
- Spec now bootstraps authentication properly — the baseline spec's missing piece; the file runs green for the first time — and covers advertisement publication, delta pushes, and the start/stop POST bodies.

## Pre-2.0 (upstream history)

- Upstream `nvx_tx.cr` as of ucla-dev @ ce19af2a18: input selection, output sync control, multicast addressing, NAX/stream-name/source polling, and the recurring poll registered in `connected` (not `on_authenticated`) so re-auth cannot leak schedules.
