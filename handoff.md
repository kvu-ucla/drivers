# Handoff — AVITS Room Verification logic module

## Branch & worktree

All work targets the **`ucla-dev`** branch. Build any worktree **off `ucla-dev`**
and commit/merge back **into `ucla-dev`** when done. Because the device drivers
are under active development on `ucla-dev`, **rebase on `ucla-dev` before merging
back**, and coordinate the NVX/DSP readback additions with their owners rather
than forking a device driver.

## Read first (repo conventions)

Before writing any code, read (in this order) and follow:
1. **`lib/placeos-driver/CLAUDE.md`** — the authoritative PlaceOS driver
   framework guide (driver structure, logic-module `system[:Module]` access,
   settings, status, spec/harness conventions).
2. **`README.md`** (repo root) — repo build/spec conventions.
3. This handoff.
Match the existing drivers' style; do not invent a new pattern. (There is no
repo-root `CLAUDE.md`/`AGENTS.md`, so nothing auto-loads — read the above.)

## Objective

Build a PlaceOS **system-scoped logic module** that actively verifies a room's
core AV devices are functioning, and records structured results for the AVITS
Room Check to consume as evidence. It orchestrates the *existing* device drivers
(calling functions they already expose); it does **not** reimplement device
protocols. Device drivers are modified **only** where a required readback is
genuinely missing (see gaps below), and only in coordination with the teams
actively developing them.

Provisional module name: `AvitsRoomVerification` (logic driver, e.g.
`drivers/place/avits_room_verification.cr` — follow the repo's logic-driver
convention).

## Why a logic module (not per-driver edits)

A PlaceOS logic module runs per-System and calls the room's device modules via
`system[:ModuleName]`. Centralizing the verification here means: one place for
the command→confirm→restore sequences, timing/timeouts, result recording, and
the read/active split — and AVITS reads **one** module's status instead of
reaching into five drivers.

## Capability audit (done 2026-08-27 — verify against current driver state)

Drivers are under active development; treat these as a snapshot and re-check.

- **Sony `bravia_pro`** — READY. `power(Bool)`, `power?`→`self[:power]`,
  `input?`→`self[:input]`, `switch_to(Input)`. Power toggle + power/input
  readback all present. No change needed.
- **Zoom `zoom_zrc`** — READY. `get_connection_state`/`self[:connection_state]`,
  `self[:online]`, `self[:paired]`, `start_instant_meeting`, `exit_meeting`,
  `self[:meeting_active]`, `self[:meeting_ended]`. Connection + start/end +
  confirmation all present. No change needed.
- **Shure `intellimix_room`** — MOSTLY. `get/set_preset`,
  `get/set_device_audio_mute`, `get/set_audio_mute(index)` present. **Gap:** no
  output-level **meter** readback to *prove program audio is flowing* after
  unmute — coordinate adding a level/meter status, or confirm via an existing
  channel indicator.
- **Crestron `nvx_tx` (encoder)** — GAP. Exposes routing (`switch_to`,
  `output`, `multicast_address`) but writes almost no status (only `WARN`).
  **Needs:** an input-signal-detected / HDMI-sync status readback.
- **Crestron `nvx_rx` (decoder)** — PARTIAL. Exposes `subscriptions` (what
  stream it's routed to) but **not** stream-lock/sync or output-signal-present.
  **Needs:** stream-lock + output-present status readbacks.

## Per-device verification (use the real functions above)

Read-only checks change nothing. Active checks capture prior state, act,
confirm via readback, then **restore**.

1. **Display (active + read-only):**
   - read-only: `input?` vs the profile's expected input.
   - active: capture `power?` → `power(true)` → poll `self[:power]` until on (timeout) →
     record → **restore prior power state**.
2. **NVX (read-only):**
   - encoder: input-signal-detected status (once exposed).
   - decoder: `subscriptions` == profile-expected stream **and** stream-lock +
     output-present (once exposed).
3. **DSP (active):**
   - capture current preset + `get_device_audio_mute` → `set_preset(expected)` →
     confirm `get_preset` → `set_device_audio_mute(false)` → confirm unmuted +
     (meter shows signal, once exposed) → **restore prior mute + preset**.
4. **Zoom (read-only + active):**
   - read-only: `self[:connection_state]` / `self[:online]`.
   - active: **abort if `self[:meeting_active]` is already true** (never touch a
     real meeting) → `start_instant_meeting` → confirm `self[:meeting_active]` →
     `exit_meeting` → confirm `self[:meeting_ended]`.

## Result schema (what AVITS reads)

Record one structured status the AVITS evidence provider ingests, e.g.
`self[:verification]` =
```
{ "ranAt": <iso8601>,
  "checks": [
    { "device": "display", "check": "power",  "type": "active",
      "result": "pass|fail|skipped|denied|unknown",
      "observed": {...}, "restored": true },
    { "device": "display", "check": "input",  "type": "read",  "result": "pass",
      "observed": {"input": "hdmi1"}, "expected": "hdmi1" },
    ...
  ] }
```
Keep it evidence-shaped (result + observed + expected + timestamp), no raw
device command/response dumps. AVITS maps each `check` to a readiness-profile
assertion.

## Constraints

- **SCOPE BOUNDARY — build ONLY the verification logic module. Do NOT modify any
  device driver** (`nvx_rx`, `nvx_tx`, `bravia_pro`, `zoom_zrc`,
  `intellimix_room`). They are under active development by their owners; the
  missing NVX/DSP readbacks are added **by the driver team, separately** — not by
  this agent. The logic module only *calls existing functions / reads existing
  status*.
- **Degrade gracefully on missing readbacks.** Display + Zoom are fully
  supported today. For DSP (meter) and NVX (signal/lock/output), where the
  readback is not yet exposed, record the check as `skipped` /
  `pending_readback` — never fail — so the module ships now for Display + Zoom
  and those checks light up automatically once the driver team exposes the
  readbacks.
- **Restore prior state** for every active check; leave the room as found.
- **Safety precondition:** for the pilot, "approved test room, verified not in
  use." The AVITS side enforces the authorization gate; this module must still
  self-guard (e.g., the Zoom `meeting_active` abort).
- **Profile-driven:** the expected input / stream / preset come from the room
  profile; the module verifies against expectation, it does not invent it.
- Follow the repo's driver + spec conventions; add a spec under the harness and
  a settings block documenting the module bindings.

## Interface with AVITS (for context)

AVITS's deterministic gate authorizes a request, then triggers this module's
verification (via the PlaceOS API) and reads `self[:verification]`. The AVITS
Bedrock agent may *request* a check; a deterministic policy authorizes it; this
module + PlaceOS execute and restore. The module never decides *whether* it is
safe to run beyond its own self-guards — that is the AVITS gate's job.

## First steps

1. Re-verify the audit against current driver state (they're moving).
2. Scaffold the logic module + a harness spec with mock device modules.
3. Implement the **ready** devices first (Display, Zoom) end-to-end, recording
   the result schema.
4. File/track the driver readback gaps (NVX signal/lock/output, DSP meter) with
   the driver owners; wire DSP + NVX once available.
