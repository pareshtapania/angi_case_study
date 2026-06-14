# Metric: `booking_conversion_rate`

## Description

The share of homeowner booking attempts that reach a **completed** service
request. "Booking attempt" means a service request (`sr_id`) for which we
observed a `booking_submitted` event — i.e. it has a row in
`fact.fct_booking_funnel`. A booking is "converted" when its current status
(per `raw.service_requests.status`, resolved through `dim_service_request`)
is `completed`.

This is a **conversion / funnel** metric, not a volume metric. It answers:
*"Of the bookings that started, what fraction finished?"*

## Owner

**Analytics** (data team alias: `analytics@angi`)
Source model owner: `fact.fct_booking_funnel` — see model header in
`models/fact/fct_booking_funnel.sql`.
Any change to the numerator/denominator logic below requires sign-off from
this team, since the metric is used in exec-facing funnel dashboards.

## Definition

```
booking_conversion_rate =
    COUNT(DISTINCT booking_key WHERE is_converted = 1)
    / COUNT(DISTINCT booking_key)
```

| | SQL | Source |
|---|---|---|
| **Numerator** | `COUNT(DISTINCT booking_key)` filtered to `is_converted = 1` | `fact.fct_booking_funnel` |
| **Denominator** | `COUNT(DISTINCT booking_key)`, no additional filter | `fact.fct_booking_funnel` |
| **Base table** | `fact.fct_booking_funnel` only. Do not recompute from `raw.service_requests` directly — that table includes SRs with **no** booking event, which would change the denominator. | |

`is_converted` is `1` iff the **current** SR status (`dim_service_request.is_current = true`)
is `completed`. `is_cancelled` and `is_matched` are *not* part of this metric
and must not be added to the numerator.

Reference SQL:

```sql
select
    sum(is_converted)                          as converted_bookings,
    count(distinct booking_key)                as total_bookings,
    sum(is_converted) / count(distinct booking_key) as booking_conversion_rate
from fact.fct_booking_funnel
```

## Grouping dimensions

### ✅ Safe — one row per `booking_key`, no fan-out

- `category_key` (service category)
- `geography_key` (city-level geography)
- `created_at_date_key` and any `dim_date` attribute joined on it
  (`year`, `month`, `week`, `is_weekend`, etc.)
- `is_matched` (as a secondary cut, e.g. "conversion rate among matched bookings")

These columns are populated by 1:1 lookups (`dim_category`, `dim_geography`,
`dim_date`) against `fct_booking_funnel`'s native grain (one row per `sr_id`).
Grouping by them does not change the denominator.

### ⚠️ Unsafe — DO NOT group by these without de-duplication

- `pro_key`, `market`, `pro_is_active` — `fct_booking_funnel` joins
  `dim_pro` **on `category_key` only** (not `sp_id`), which is a
  one-to-many join whenever a category has more than one active pro.
  Grouping by `pro_key`/`market` will fan out `booking_key` rows, inflating
  both numerator and denominator and producing a conversion rate that no
  longer reflects "per booking."
- `session_key` — `fct_booking_funnel.session_key` is derived from
  `dim_session` via `fct_booking_events`, and defaults to `'unknown'` when
  no session match exists. Grouping by it can silently bucket many bookings
  into a single `'unknown'` group; not meaningful as a conversion cut.
- Any column from `dim_pro` or `dim_session` not listed above.

If a pro- or session-level cut of this metric is genuinely needed, it must
be computed from a purpose-built model that joins at the correct grain
(e.g. `sp_id` + `category_key`, not `category_key` alone) — not from
`fct_booking_funnel` as-is.

## Structural guardrail

**`booking_key` must be unique in `fct_booking_funnel`.** This metric is
only valid if:

```sql
select count(*) = count(distinct booking_key) from fact.fct_booking_funnel
```

returns `true`. Because of the `dim_pro` fan-out described above, this
*can* be violated today if a category has multiple active pros. Add (or
verify) a dbt `unique` test on `booking_key` for `fct_booking_funnel`, and
treat a failing test as a P1 — the conversion rate is silently wrong
(inflated denominator, and numerator inflated proportionally for converted
SRs in fanned-out categories) until it's fixed.

A second guardrail: numerator must always be a **subset** of denominator
(`is_converted = 1 ⟹ included in denominator`, trivially true since both
read from the same table/filter). Any query that computes numerator and
denominator from *different* filtered base sets (e.g. denominator from
`raw.service_requests`, numerator from `fct_booking_funnel`) is not this
metric and will not reconcile.

## What this metric should NOT be used for

- **Not a session→booking conversion rate.** This metric's denominator is
  "bookings submitted" (already in `fct_booking_funnel`), not "sessions
  started." For session-level funnel analysis, use `fct_session_events` /
  `dim_session` and a separate metric (e.g. `session_to_booking_rate`).
- **Not a real-time / point-in-time-stable number.** `dim_service_request`
  is SCD Type 2 with a 1-day incremental lookback; an SR's status (and
  therefore `is_converted`) can change after the booking was submitted
  (`submitted → matched → completed`, possibly days later). Re-running this
  metric for the same historical date range can produce a different value
  than it did yesterday. Do not use this metric to assert "as of date X, the
  rate was Y" without also pinning `dw_updated_at` / a snapshot.
- **Not a pro-level or market-level performance metric** (see "unsafe
  dimensions" above) — do not use it to rank pros, markets, or categories by
  "conversion rate per pro."
- **Not a cancellation-rate proxy.** `1 - booking_conversion_rate ≠
  cancellation rate`, because the remainder includes SRs that are still
  `submitted`/`matched` (in-flight), not only `cancelled`. Use
  `is_cancelled` directly for cancellation rate.
- **Not additive across time grains in a weighted-average sense.** Always
  recompute `SUM(is_converted) / COUNT(DISTINCT booking_key)` at the target
  grain — never average daily conversion rates across days to get a
  weekly/monthly rate.
