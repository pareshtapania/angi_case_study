# Model Changes: fct_session_events Metrics Enhancement

## Overview

Enhanced `fct_session_events` with 20 new metrics across three categories: site-level, page-level, and event-specific. The model grain remains unchanged (one row per raw user event).

## Files Modified

- `angi_case_study/models/fact/fct_session_events.sql` — added new CTEs and columns
- `angi_case_study/models/fact/_fct__models.yml` — added full column documentation and tests for `fct_session_events`

## New CTEs Added

| CTE | Purpose |
|---|---|
| `session_aggs` | Pre-aggregates event counts per session to avoid repeated window functions |
| `sequenced` | Adds event ordering, lag timestamps, and session first/last event via window functions |

## New Metrics

### Site-Level Metrics

Aggregatable across all events/sessions for overall site engagement and performance.

| Column | Type | Description |
|---|---|---|
| `session_started_at` | timestamp | Session start time from dim_session |
| `session_ended_at` | timestamp | Session end time (null for abandoned/crashed sessions) |
| `session_duration_sec` | integer | Total session duration in seconds |
| `is_clean_end` | boolean | Whether the session ended cleanly |
| `session_event_count` | integer | Total events in this session |
| `is_bounce_session` | integer (0/1) | 1 if session has exactly one event |
| `seconds_since_session_start` | integer | Seconds from session start to this event |

**Example queries:**
- Bounce rate: `SUM(is_bounce_session * is_first_event_in_session) / COUNT(DISTINCT session_key)`
- Avg session depth: `AVG(session_event_count)` (filter to `is_first_event_in_session = 1` for per-session avg)
- Avg session duration: `AVG(session_duration_sec)` (filter to `is_first_event_in_session = 1`)

### Page-Level Metrics

Page type at session entry point with boolean flags for filtering and grouping.

| Column | Type | Description |
|---|---|---|
| `page_type` | varchar | Page type at session start (home, search, booking_form, confirmation) |
| `is_home_page` | integer (0/1) | 1 if session started on home page |
| `is_search_page` | integer (0/1) | 1 if session started on search page |
| `is_booking_form_page` | integer (0/1) | 1 if session started on booking form page |
| `is_confirmation_page` | integer (0/1) | 1 if session started on confirmation page |

**Example queries:**
- Events by entry page: `SELECT page_type, COUNT(*) FROM fct_session_events GROUP BY page_type`
- Booking rate by entry page: `SELECT page_type, SUM(is_booking_submitted) / COUNT(DISTINCT session_key) FROM fct_session_events GROUP BY page_type`

### Event-Specific Metrics

Per-event sequencing, timing, and session-level classification.

| Column | Type | Description |
|---|---|---|
| `event_sequence_number` | integer | Ordinal position within session (1-based) |
| `is_first_event_in_session` | integer (0/1) | 1 if first event in session |
| `is_last_event_in_session` | integer (0/1) | 1 if last event in session |
| `seconds_since_prev_event` | integer | Seconds since previous event (null for first event) |
| `has_sr_id` | integer (0/1) | 1 if event carries a service request ID |
| `session_booking_started_count` | integer | Total booking_started events in session |
| `session_booking_submitted_count` | integer | Total booking_submitted events in session |
| `session_pro_viewed_count` | integer | Total pro_viewed events in session |
| `session_has_booking_submitted` | integer (0/1) | 1 if session contains any booking_submitted event |

**Example queries:**
- Avg time between events: `AVG(seconds_since_prev_event)` (where `event_sequence_number > 1`)
- Funnel drop-off: Compare `SUM(is_booking_started)` vs `SUM(is_booking_submitted)` to see how many sessions start but don't complete a booking
- Sessions with conversions: `SELECT COUNT(DISTINCT session_key) FROM fct_session_events WHERE session_has_booking_submitted = 1`

## Dependencies

No new model dependencies added. The model still depends on:
- `source('raw', 'raw_events')` — raw event data
- `ref('dim_session')` — now pulling additional columns: `started_at`, `ended_at`, `session_duration_sec`, `page_type`, `is_clean_end`

## Tests Added

- `event_key`: unique + not_null (severity: error)
- `event_id`: not_null
- `event_type`: not_null + accepted_values (severity: warn)
- `event_ts`: not_null
- `dw_updated_at`: not_null
