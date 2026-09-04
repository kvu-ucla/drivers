# Zoom Booking Converter (UCLA)

**Version:** 1.0.0 — the UCLA-maintained line diverging from upstream.

> UCLA-maintained copy of `drivers/zoom/booking_converter.cr` (vendored 2026-09-04 from ucla-dev @ b479ebe0a5), repointed from the retired ZoomCSAPI module to the Zoom ZRC module's `meetings` status.

## Overview

Logic driver (no transport) that subscribes to another module's meetings-list status and republishes it as PlaceOS calendar-event statuses. **Status-shape compatible** with the upstream converter — generic name `Bookings`, same status keys and event field set — but not a behavioural drop-in for every consumer: `body`/`location` are empty (see [Known limitations](#known-limitations)), so consumers that extract a join link from `event.body` are unsupported. Bookings are sorted by start time; current/next are recomputed immediately on every list change and refreshed by a per-minute cron (with 0–1s jitter to spread redis load).

## Settings

| Key | Type | Default | Description |
|---|---|---|---|
| `booking_source` | Object | `{module: "ZoomZRC_1", status: "meetings"}` | Module reference and status key to subscribe to. Changing it re-subscribes on the next settings update; the old source is fully unsubscribed. |

## Source data shape (dual casing)

The ZRC wrapper writes the same `meetings` status from two paths with **different key casing**:

- `GET /meetings/list` responses: snake_case (`meeting_number`, `meeting_name`, `start_time`, `end_time`, `is_private`, `is_all_day_event`) via `meeting_item_to_dict`.
- `OnUpdateMeetingList` push events: raw pybind camelCase attribute names (`meetingNumber`, `startTime`, …) via the wrapper's generic `_pybind_to_jsonable`.

The converter underscore-normalizes every entry's keys before parsing, so both spellings map to one `ZRCMeeting` declaration. `start_time`/`end_time` are RFC3339 strings.

## Skip policy (by design)

UCLA ZRC room calendars contain **only Zoom meetings**. An entry without a top-level meeting number is skipped by design — third-party (Teams/Webex) events and plain calendar holds are never scheduled on these calendars, so `third_party_meeting_info` is intentionally ignored. Entries with blank/unparseable times are also skipped (this covers instant meetings, which are not calendar bookings). Each skip logs a warning.

## Failure posture

- An explicit `null` payload (source status deleted/cleared) **clears** bookings and booking state.
- Any other unparseable or non-array payload logs a warning and **keeps last-known-good** state — a source glitch is never conflated with "no meetings".

## Status keys

| Key | Description |
|---|---|
| `bookings` | Array of calendar events, sorted by `event_start` (unix seconds). `id` is the Zoom meeting number as a string; `title` is the meeting name; `private`/`all_day` come from the ZRC flags. |
| `current_booking` | The event covering now, else absent. The driver assigns `nil`, which PlaceOS status storage implements as key deletion: readers find the key missing (`[]?` → nil, `[]` raises), while subscribers receive a `null` notification. |
| `booking_in_progress` | Bool. |
| `next_booking` | The first event starting after now, else absent (same nil-delete semantics as `current_booking`). |

## Known limitations

- `body` and `location` are empty strings: the ZRC meetings list carries no location, and no join URL is synthesized. Consumers that extract a join link from `event.body` (e.g. `drivers/zoom/zoom_meeting.cr`) are **not supported** — UCLA rooms join via the ZRC module using the meeting number (`id`).
- Occurrences of a recurring meeting share the same `id` (the Zoom meeting number), matching the upstream converter's contract.
