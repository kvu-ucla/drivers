# Session handoff / resume pointer — 2026-09-01

Supersedes the AVITS Room Verification handoff (previous content of this file;
recoverable via `git show d478a84b22:handoff.md`). Start a fresh session by
reading THIS file first. Role, workflow, and conventions live in the project
memory (`ucla-vendored-drivers-folder`, `ucla-review-loop-workflow`,
`herdr-agents-in-tabs`, `no-commit-attribution-footers`,
`running-driver-specs-locally`) — not restated here.

## Landing (all on `ucla-dev`, all PUSHED to origin as of cd6bf7e92e — verified)

- **Vendored UCLA driver folder** — 13 commits `ec55541ad7..bb0cacc2ae`:
  12 KAPLAN-A26 drivers + shared deps + meet/router tree copied into
  `drivers/ucla/` with provenance headers and `(UCLA)` name suffixes.
  bravia re-based on production pin `ca4750ac07`; cres_proc (driver+spec)
  re-based on `ucla-drivers@4de617d9c7`
  (repo at `/Users/khvu91/Documents/GitHub/drivers/repositories/ucla-drivers`).
  Verified: all compile `-Dplaceos_all_transports`.
- **DeviceInfo across all 10 device drivers** — inside the same 13 commits;
  5 independent codex review rounds converged 16→7→2→1→0 findings
  (final verdict PASS). Six driver specs green (tsw_1070, bravia,
  intellimix_room, pearl, cgi_protocol, occupancy_sensor — three of them green
  for the first time ever locally). Four production bugs fixed en route:
  intellimix `lstrip` REP parsing, NVX-base fallible `device_info`,
  `Version`-as-firmware misreporting, cgi baseline spec 8-min stall.
- **NVX StreamLocation routing** — `bb85f605f7` (nvx_tx), `52927092f5`
  (nvx_rx), `bec15c0d73` (virtual_switcher + NEW spec). tx advertises
  `stream_location` (SDK-verified GET-only), rx routes via POST (loud-error on
  device rejection), switcher publishes routes / routes_actual / routes_detail
  / transmitters_active with generation+mutex-serialized topology lifecycle.
  3 codex rounds → PASS (a mid-loop segfault was traced to a pre-existing
  String#inspect log defect, not the lock design). nvx_tx spec now green
  (missing auth bootstrap was its only baseline defect).
- **12 driver readmes v2.0.0** — commits `6d66b4a712..44c6732639`
  (`<driver>_readme.md` beside each driver). 2 codex accuracy rounds → PASS.
  meet readme corrects two inherited doc errors (`qsc_phone` key,
  `merge_outputs` nesting).
- **12 header-touch commits** — `382af48488..cd6bf7e92e`: one comment line per
  driver `.cr` (`# Version 2.0.0 — documentation: ..._readme.md`) so the
  Backoffice commit picker gains a commit containing the readme (readme is
  served at the driver's pinned commit; readme-only commits never appear in
  the picker). Verified: all compile.
- **Backoffice readme 404 root cause** — rest-api `drivers.cr` serves
  `<file>_readme.md` at `current_driver.commit` from the repo REMOTE; naming
  convention confirmed correct. Fix = repoint drivers (see open items).
- **Backoffice module-create bug diagnosed (upstream)** — system-page
  "Add Module" templates `control_system_id` unconditionally
  (`system-state.service.ts:322`); form submit deletes it from form_value but
  not from the spread `item_json` (`module-form.component.ts` submit), so
  non-logic creates 400 ("should not be associated for Websocket modules",
  `models/module.cr:99`). Workaround verified by Kenneth: create from
  top-level Modules page, then add-existing to the system.

## Owner decisions / open items (each with what it unblocks)

1. **Repoint each Backoffice driver record to its `chore(ucla/...)` header-touch
   commit** (or later) — unblocks the readme tab (404s until then). Kenneth
   does this in Backoffice per driver; PlaceOS handles module repointing to the
   ucla paths on their end.
2. **File the Backoffice bug upstream?** — a two-line fix in `submit()` (delete
   `control_system_id` from the merged payload for non-logic). Kenneth's call
   (outward-facing); unblocks system-page module adds without the workaround.
3. **ppnd auto-unmute defect** — `switch_to` tests `self[:mute]?` but shutter
   publishes `av_mute` (`ppnd.cr:257` vs `298-323`; documented in its readme
   Known issues) — a future fix round unblocks shuttered-projector switching.
4. **Declared-but-unread settings** — `normally_open` (cres_proc),
   `poll_channels`/`channel_count` (intellimix), `enable_https` (ppnd) —
   fix or remove in a future round; unblocks honest settings surface.
5. **cres_proc accepted pin defects** — `as_bool? ||` loses literal JSON
   `false` (latent: bridge sends strings) and pinned spec `settings({})` parse
   error — deliberate future fixes.
6. **Remaining red baseline specs** — nvx_rx image-section (40s schedule vs
   500ms should_send) and ppnd (on_load blocks on unserviced query) — spec
   surgery, separate pass.
7. **Dormant Xio machinery in nvx_rx** — deliberate removal pass once
   StreamLocation routing is proven in rooms.
8. **StreamLocation rollout config** — rooms need switcher settings in the new
   shape (`transmitters`/`receivers` friendly-name→module maps; see
   virtual_switcher_readme). Switch re-establishment latency ~1–2 s accepted.
9. **Design doc is untracked** (`docs/` is gitignored) — decide: force-add,
   relocate, or leave on-disk only.
10. **Kenneth's own working-tree items** (not this project's): zoom_zrc driver+
    spec modifications, staged `.claude/skills`, staged
    `report_failures/zoom_zrc_nonprod_2026-08-17.md`.

## Where things live

| Thing | Location |
| --- | --- |
| Vendored drivers + readmes | `drivers/ucla/**` (ucla-dev, pushed) |
| StreamLocation design doc | `docs/superpowers/specs/2026-08-31-nvx-streamlocation-routing-design.md` (on disk, gitignored) |
| Production pins | bravia `ca4750ac07` (this repo); cres_proc `4de617d9c7` (`~/Documents/GitHub/drivers/repositories/ucla-drivers`) |
| Review verdicts + impl summaries + briefs | session scratchpad `/private/tmp/claude-502/-Users-khvu91-Documents-drivers/0386b55b-*/scratchpad/` (`codex-*.md`, `impl-*.md`, `*-brief.md`) — tmp, may not survive reboot; all conclusions are encoded in commits/readmes/this file |
| Backoffice bug evidence | `PlaceOS/backoffice` `src/app/systems/system-state.service.ts:319-330`, `src/app/modules/module-form.component.ts` (submit), `PlaceOS/models` `src/placeos-models/module.cr:91-110`, `PlaceOS/rest-api` `controllers/drivers.cr` (readme endpoint) |
| Prior AVITS handoff | `git show d478a84b22:handoff.md` |
