# Crestron Occupancy Sensor (UCLA)

**Version:** 2.0.0 — the UCLA-maintained line diverging from upstream.

> UCLA-maintained copy of `drivers/crestron/occupancy_sensor.cr` (vendored 2026-08-30 from ucla-dev @ ce19af2a18). Shares `cres_next_auth.cr` with the NVX and TSW drivers.

## Overview

Crestron occupancy sensor (e.g. CEN-ODT family) over HTTPS. The device has no websocket interface, so after cookie authentication (10-minute re-auth schedule) the driver runs a `/Device/Longpoll` event monitor for real-time `IsRoomOccupied` updates and exposes the result through `Interface::Sensor` (a single presence sensor detail) as well as plain status keys. Implements `Interface::DeviceInfo`: identity is mapped from the full `/Device` payload and cached, with an honest static fallback (make `Crestron`, model `Occupancy Sensor`, configured host) when a query fails.

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
| `occupied` | Boolean room occupancy from `IsRoomOccupied`. |
| `presence` | `1.0` when occupied, `0.0` when not (sensor-interface value). |
| `mac` | Device MAC address (normalised lowercase hex). |
| `name` | Device name from `DeviceInfo` (nil when unset). |
| `authenticated` / `auth_error` | Session state published by the shared auth module. |
| `device_info` | Common descriptor published by the DeviceInfo interface. |

## Exec methods

| Method | Description |
|---|---|
| `poll_device_state` | One full `/Device` fetch serving both paths: identity is mapped and cached **first**, then occupancy is updated (so the exported sensor detail carries real mac/name). |
| `device_info` | Identity only — fetch, map, cache; never mutates occupancy. Serves cached/static details on failure. |
| `sensors(type, mac, zone_id)` | Sensor-interface listing (presence type only). |
| `sensor(mac, id)` | Single sensor lookup. |
| `get_sensor_details` | Returns the current sensor detail record. |
| `authenticate` / `logout` | Session management (shared auth module). |

## 2.0.0 (2026-08-31)

- Vendored from ucla-dev @ ce19af2a18 with DeviceInfo fixes.
- Identity mapping separated from occupancy mutation: `device_info` is a pure identity path, while `poll_device_state` maps and caches identity **before** creating/updating the sensor detail — so the first exported detail carries the real mac/name instead of empty values.
- `device_info` made infallible: request/parse failures serve the cached descriptor or an honest static fallback, so a payload missing `IsRoomOccupied` can no longer block identity publication. Occupancy parsing is tolerant (`dig?`/`as_bool?`) — a literal `false` still publishes.
- Firmware reads `DeviceVersion` (with labelled `puf`/`built` values), not the payload's schema `Version`; model falls back to `Occupancy Sensor` via presence checks.
- Shared auth hardening: `authenticate` gained a `lifecycle` flag (transient session-refresh failures in sibling drivers can't tear down schedules) and pre-response failures (timeout/refusal/TLS) publish `authenticated = false` and `auth_error` before re-raising.
- Spec: the first auth expectation's timeout raised to 5 seconds, removing a deterministic race between the 1-second scheduled `authenticate` and the harness's 1-second default expectation timeout.

## Pre-2.0 (upstream history)

- Upstream `occupancy_sensor.cr` as of ucla-dev @ ce19af2a18: long-poll event monitor, sensor-interface plumbing, 10-minute re-authentication schedule.
