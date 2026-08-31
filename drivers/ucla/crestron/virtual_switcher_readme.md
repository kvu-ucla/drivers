# Crestron Virtual Switcher (UCLA)

**Version:** 2.0.0 — the UCLA-maintained line diverging from upstream.

> UCLA-maintained copy of `drivers/crestron/virtual_switcher.cr` (vendored 2026-08-30 from ucla-dev @ ce19af2a18), rewritten for StreamLocation routing per `docs/superpowers/specs/2026-08-31-nvx-streamlocation-routing-design.md`.

## Overview

Logic driver (no transport) that routes video across Crestron NVX endpoints declared in settings. A route is one read and one write: it reads the transmitter module's advertised `stream_location` status (an RTSP URI) and calls `switch_stream_location` on the receiver module. Audio routing hands the transmitter's `nax_address` (AES67) to a configured audio-sink function. Missing advertisements and unconfigured inputs raise — routes never silently no-op. Implements `Interface::Switchable(String, Int32 | String)` and `Interface::Muteable`. Generic name `Switcher`.

Alongside commanded intent, the driver maintains a live routing table derived from each receiver's reported `stream_location`, so out-of-band changes (device UIs, reboots, other controllers) are visible.

## Settings

| Key | Type | Default | Description |
|---|---|---|---|
| `transmitters` | Hash(String, String) | `{"PC" => "Encoder_1"}` | Friendly input name → transmitter module reference. |
| `receivers` | Hash(String, String) | `{"Projector" => "Decoder_1"}` | Friendly output name → receiver module reference. Legacy `Int32` outputs resolve by finding `Decoder_<n>` among these module refs. |
| `audio_sink` | Object | `{module_id: "Mixer_1", function_name: "set_string", arguments: ["aes67_control_id"], named_args: {}}` | The transmitter's `nax_address` is appended to `arguments` and the function invoked on the module. Blanking sends `""` (preserving the old mute-audio behaviour). |

## Status keys

| Key | Description |
|---|---|
| `inputs` / `outputs` | Configured friendly input/output names. |
| `routes` | Commanded intent: output → input (nil once blanked; entry removed if the output is deconfigured). |
| `routes_actual` | Observed truth, derived from each receiver's reported `stream_location` reverse-mapped to the advertising transmitter. Always carries the full output key set (nil until a receiver reports); `unknown:<uri>` when no configured transmitter advertises the URI. |
| `routes_detail` | Per output: `{input, tx_module, rx_module, stream_location, tx_host, rx_host}`. Hosts come from each module's published `device_info.ip_address` — nil when unavailable, never fabricated. |
| `transmitters_active` | Inverse view: input → outputs currently observed receiving it. |

Intent/actual divergence logs a warning (only for outputs that have a recorded intent, so boot-time reports don't warn spuriously).

## Exec methods

| Method | Description |
|---|---|
| `switch_to(input)` | Routes the input to **all** configured outputs. |
| `switch(map, layer)` | Routes `{input => [outputs]}` per layer (All/Video/Audio). Blank inputs: `none`, `break`, `clear`, `blank`, `black`, `0`. |
| `mute(state, index, layer)` | Mute-only (no unmute): blanks the given output on the mapped layer. |
| `available_inputs` / `available_outputs` | Configured friendly names. |
| `power(state)` | No-op stub to suppress errors in routing logic. |

## 2.0.0 (2026-08-31)

- Vendored from ucla-dev @ ce19af2a18 (unchanged logic driver), then rewritten from subscription-table lookups to the settings-declared topology above.
- Route delivery: read tx `stream_location` → `rx.switch_stream_location(uri)`; no Xio subscription-table or `/AvRouting` involvement. Missing/blank advertised location or unconfigured input raises. NAX audio-sink handoff unchanged from the original design.
- Live routing table: `routes` (intent), `routes_actual` (device readback incl. `unknown:<uri>` and nil), `routes_detail` (modules, URI, hosts from `device_info`), `transmitters_active`; divergence warning.
- Concurrency hardening: topology loads are generation-counted and mutex-serialized with subscription-callback commits, so stale observations cannot survive or resurrect across settings updates; in-flight routes revalidate the topology after the remote call in both the route and blank branches (a stale blank cannot touch a newly configured audio sink). Derived records are seeded with the full output key set before subscriptions register.
- Fixed a Crystal codegen segfault found during verification: interpolating a union-typed local (assigned inside an `&&` condition) in the divergence-warning log closure crashed in `String#inspect`; the message is now built eagerly in method context.
- New spec: whole-record assertions, key-set parity between `routes_actual`/`routes_detail`, remap/removal, delayed-receiver in-flight races, stale-callback commits, and divergence handling. Reviewed to PASS over three independent review rounds.

## Pre-2.0 (upstream history)

- Upstream virtual switcher as of ucla-dev @ ce19af2a18 routed by enumerating `Crestron::Transmitter`/`Crestron::Receiver` modules and looking up Xio subscription tables (`get_streams`, name maps); that machinery is fully replaced in 2.0.0.

## Known issues / residuals

- **`routes_actual` reverse-map timing:** only receiver `stream_location` is subscribed. A transmitter that advertises *after* a receiver report leaves an `unknown:<uri>` entry until the next receiver status change. If that bites in practice, subscribing to transmitter `stream_location` and re-deriving is a small follow-up.
