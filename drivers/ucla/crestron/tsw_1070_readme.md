# Crestron TSW-1070 Touch Screen (UCLA)

**Version:** 2.0.1 — the UCLA-maintained line diverging from upstream.

> UCLA-maintained copy of `drivers/crestron/tsw_1070.cr` (vendored 2026-08-30 from ucla-dev @ ce19af2a18). Shares `cres_next_auth.cr` with the NVX and occupancy-sensor drivers.

## Overview

Crestron TSW-70 series touch panel over its HTTPS JSON API (requires firmware 3.002.0034.001 or later; the device does not support a websocket, so the driver long-polls `/Device/Longpoll` for real-time updates). Cookie authentication with a 10-minute re-auth schedule. Implements `Interface::DeviceInfo`: `self[:device_info]` is always the common Descriptor shape, with the rich Crestron payload available separately under `device_info_raw`. Generic name `TouchPanel`.

## Settings

| Key | Type | Default | Description |
|---|---|---|---|
| `username` | String | `"admin"` | Device login. |
| `password` | String | `"admin"` | Device login password. |
| `http_keep_alive_seconds` | Int | `600` | HTTP connection keep-alive. |
| `http_max_requests` | Int | `1200` | Max requests per HTTP connection. |

## Status keys

| Key | Description |
|---|---|
| `device_info` | Common descriptor (make `Crestron`, model with category prefix, serial, firmware, MAC, IP, hostname). Long-poll deltas are merged into the last full snapshot before publishing, so identity fields survive partial updates. |
| `device_info_raw` | The device's full `DeviceInfo` payload (Crestron shape), for consumers needing fields the descriptor omits. |
| `authenticated` / `auth_error` | Session state published by the shared auth module. |

## Exec methods

| Method | Arguments | Description / returns |
|---|---|---|
| `device_info` | — | Fetches `/Device/DeviceInfo`, publishes `device_info_raw`, and returns the `Descriptor`. Infallible: failures serve the last good descriptor or an honest static fallback (`Crestron` / `TSW-1070` / configured host). |
| `authenticate` | `lifecycle : Bool = true` — `false` isolates a failed login from the connection lifecycle | Session login (shared auth module); publishes `authenticated` / `auth_error`. |
| `logout` | — | Ends the session and disconnects. Returns `Bool` (success). |

## 2.0.1 (2026-09-08)

- Documentation: Exec methods table now states argument types and return types (no code change).

## 2.0.0 (2026-08-31)

- Vendored from ucla-dev @ ce19af2a18 and conformed to the DeviceInfo interface: `self[:device_info]` is Descriptor-shaped everywhere (the rich Crestron payload moved to `device_info_raw`), and the interface owns the polling cadence.
- Long-poll `DeviceInfo` responses are partial objects; they are now parsed as deltas and merged into the last full snapshot (non-nil fields overlay) instead of erasing identity. If no snapshot exists yet, the driver refetches rather than publishing an unmerged delta.
- Firmware reports the device's `DeviceVersion` (leading), with labelled `puf` version and build date — not the payload's API-schema `Version`.
- `device_info` made infallible with a cached/static fallback so `on_authenticated` can always proceed to start the long-poll monitor after a transient error.
- Shared auth hardening: `authenticate` gained a `lifecycle` flag and pre-response failures (timeout/refusal/TLS) publish `authenticated = false` and `auth_error` before re-raising.
- Stale spec rewritten, including partial-delta coverage (a `Name`-only delta updates the hostname while serial/firmware/MAC survive).

## Pre-2.0 (upstream history)

- Upstream `tsw_1070.cr` as of ucla-dev @ ce19af2a18: HTTPS JSON API access, long-poll event monitor, 10-minute re-authentication schedule.
