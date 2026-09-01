# Shure IntelliMix Room Audio Processor (UCLA)

**Version:** 2.0.1 — the UCLA-maintained line diverging from upstream.

> UCLA-maintained copy of `drivers/shure/intellimix_room.cr` (vendored 2026-08-30 from ucla-dev @ ce19af2a18).

## Overview

Controls Shure IntelliMix Room DSP software over its TCP command-string protocol (port 2202, ` >`-terminated frames, `< GET/SET … >` verbs per the Shure command-strings documentation). On connect the driver queries identity once (`GET MODEL`, `GET FW_VER`, `GET DEVICE_ID`) and then polls live state with `GET ALL` every 50 seconds at priority 0 so the poll never preempts queued commands. Implements `Interface::Muteable` (device audio mute) and `Interface::DeviceInfo` (descriptor served from cached status; republished automatically when the device reports a changed model/firmware/serial). Generic name `Mixer`.

## Settings

The driver has no settings.

## Status keys

Status keys are derived from `< REP … >` responses:

| Key pattern | Description |
|---|---|
| `<param>` | Single-value parameters, lowercased — e.g. `model`, `fw_ver`, `device_id`, `serial_num`, `preset`, `device_audio_mute`. |
| `<param>_<channel>` | Channel-scoped parameters — e.g. `audio_mute_01`, `audio_gain_hi_res_03`. |
| `<param>_<input>_<output>` | Matrix parameters — e.g. `matrix_mxr_route_01_02`, `matrix_mxr_gain_01_02`. |
| `device_info` | Common descriptor published by the DeviceInfo interface. |

## Exec methods

| Method | Description |
|---|---|
| `query_device_identity` | One-shot `GET MODEL` / `GET FW_VER` / `GET DEVICE_ID` (also run on connect). |
| `get_all` | Full state dump (`GET ALL`). |
| `device_info` | Descriptor from cached status: make `Shure`, model with `IntelliMix Room` fallback, serial (`serial_num`), firmware (`fw_ver`), configured IP. |
| `get_preset` / `set_preset(number)` | Preset recall (numbers zero-padded to 2 digits on the wire). |
| `get_device_audio_mute` / `set_device_audio_mute(mute)` | Device-wide audio mute. |
| `get_audio_mute(index)` / `set_audio_mute(index, mute)` | Per-channel mute. |
| `get_audio_gain_hi_res(index)` / `set_audio_gain_hi_res(index, value)` | Per-channel high-resolution gain. |
| `get_audio_gain_postgate(index)` / `set_audio_gain_postgate(index, gain)` | Post-gate gain. |
| `get_automxr_mute(index)` / `set_automxr_mute(index, mute)` / `get_automxr_gate(index)` | Automixer controls. |
| `get_matrix_mxr_route(input, output)` / `set_matrix_mxr_route(input, output, enabled)` | Matrix routing. |
| `get_matrix_mxr_gain(input, output)` / `set_matrix_mxr_gain(input, output, gain)` | Matrix gain. |
| `get_denoiser_enable(index)` / `set_denoiser_enable(index, enable)` / `get_denoiser_level(index)` / `set_denoiser_level(index, level)` | Denoiser (level `LOW`/`MEDIUM`/`HIGH`). |
| `get_onhook_enable` / `set_onhook_enable(enable)` | On-hook behaviour. |
| `get_na_device_name` / `get_chan_config` / `get_chan_count` | Device/channel queries. |
| `get_lic_exp_date` / `get_lic_type` / `get_lic_valid` | Licensing queries. |
| `mute(state, index, layer)` | Muteable interface — maps audio layers to `set_device_audio_mute`. |

## 2.0.1 (2026-09-01)

- Removed the unread `poll_channels` and `channel_count` settings (honest settings surface; the recurring `GET ALL` poll already covers every channel).

## 2.0.0 (2026-08-31)

- Vendored from ucla-dev @ ce19af2a18 with DeviceInfo support: cache-read descriptor, identity queried once per connection; the 50-second schedule now polls live state only (`GET ALL` at priority 0). `received` republishes the descriptor when a cached identity key (`model`/`fw_ver`/`serial_num`) changes value — e.g. `GET ALL` reporting new firmware after an upgrade.
- **Fixed a production parsing bug:** the response parser used `lstrip("< REP ")`, but `String#lstrip(String)` strips a character *set* — any REP parameter starting with `P`, `R`, `E`, `<` or space was mangled (e.g. `< REP PRESET 3 >` parsed as `SET 3`, publishing `self[:set]` instead of `preset`). Replaced with an anchored `sub(/\A<\s*REP\s+/, …)`.
- Model fallback via presence checks covers the empty braced value `< REP MODEL {} >` that the anchored parser can legitimately cache.
- Spec: latent defects behind the previously-stalled `GET ALL` fixed (unanswered poll had made half the file unreachable); first full pass of this spec on record.

## Pre-2.0 (upstream history)

- Upstream `intellimix_room.cr` as of ucla-dev @ ce19af2a18: the command-string control surface above, with identity re-queried inside the recurring 50-second poll.

## Known issues / residuals

- `serial_num` (and thus the descriptor's serial) only populates if the device reports it via `GET ALL` — the `SERIAL_NUM` verb is unverified for this software product, so no dedicated query was added.
