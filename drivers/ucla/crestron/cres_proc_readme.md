# Crestron - SIMPL Interface (UCLA)

**Version:** 2.0.1 — the UCLA-maintained line diverging from upstream.

> UCLA-maintained copy of `drivers/crestron/cres_proc.cr` (vendored 2026-08-30 from ucla-drivers @ 4de617d9c7). Based on the production pin — the commit production actually runs — rather than repo HEAD.

## Overview

Talks to a SIMPL bridge program running on a Crestron processor over raw TCP (port 9001, `\r\n`-terminated frames). The bridge exposes a single digital I/O point: the driver sends `query` every 50 seconds and parses a one-line JSON response containing `digital-io1`, publishing it as a boolean `state`. Implements `Interface::DeviceInfo` with an honest mostly-nil descriptor (the bridge exposes no identity information).

## Settings

The driver has no settings. No credentials are required.

## Status keys

| Key | Description |
|---|---|
| `state` | Boolean state of `digital-io1` as reported by the bridge. Only published once a valid value has been received. |
| `device_info` | Common descriptor published by the DeviceInfo interface: make `Crestron`, model `SIMPL Interface`, configured IP; all other fields nil. |

## Exec methods

| Method | Description |
|---|---|
| `query` | Sends `query\r\n` to the bridge; the response updates `state`. |
| `do_poll` | Alias for `query` (used by the 50-second poll). |
| `state` | Returns the cached boolean state (nil until first response). |
| `device_info` | Returns the static descriptor described above. |

## 2.0.1 (2026-09-01)

- Removed the unread `normally_open` example setting from `default_settings` (honest settings surface — the pinned base has no inversion logic reading it).

## 2.0.0 (2026-08-31)

- Vendored from the production pin `ucla-drivers @ 4de617d9c7`; the spec was taken byte-identical from the pin.
- Added `Interface::DeviceInfo`: honest mostly-nil descriptor (make `Crestron`, model `SIMPL Interface`, configured IP) — the bridge only exposes digital I/O state, so nothing else is fabricated.

## Pre-2.0 (upstream history)

- The pinned base parses booleans via `extract_bool?` (JSON bools, `"on"`-style strings, 1/0 ints), has no `normally_open` inversion logic, and publishes state on `on_update`.

## Known issues / residuals

- **Accepted pin defect:** `extract_bool?` uses `any.as_bool? || (fallback)`, so a literal JSON `false` short-circuits into the fallback, which returns nil ("unrecognized boolean payload") — `state` never goes false from a real JSON boolean. Strings (`"false"`, `"off"`) and `0` work correctly.
- **Accepted pin defects in the spec:** the pinned spec's `settings({})` is a Crystal parse error (the file does not compile verbatim), and two of its seven examples fail against the pin itself (the JSON-`false` case above, and `exec(:query).get` awaiting a device response the spec never provides). Left verbatim to match the pin.
