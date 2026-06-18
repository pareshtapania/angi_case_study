# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

Activate the virtual environment before running any dbt commands:

```bash
source dbt_venv/bin/activate
```

Common commands (run from the `angi_case_study/` subdirectory):

```bash
dbt run                                  # run all models
dbt run --select dim_pro                 # run a single model
dbt run --select tag:fact                # run by tag
dbt test                                 # run all tests
dbt test --select fct_booking_funnel     # test a single model
dbt run --full-refresh                   # full refresh (bypasses incremental logic)
dbt deps                                 # install packages (dbt_utils)
dbt clean                                # remove target/ and dbt_packages/
```

The dbt profile is `angi_case_study` and must be configured in `~/.dbt/profiles.yml` pointing to Snowflake (database: `angi`).

## Architecture

### Layer structure

```
raw sources (angi.raw.*)
    └── dimension models  →  deployed to schema: dimension
    └── fact models       →  deployed to schema: fact
```

The `get_custom_schema` macro in `macros/get_custom_schema.sql` strips the `target.schema` prefix so models deploy directly into `dimension` and `fact` (not `dev_dimension` / `prod_dimension`).

### Raw sources (`models/raw/_raw__sources.yml`)

| Table | Grain | Key mutability note |
|---|---|---|
| `raw_events` | one row per user event | immutable after insert |
| `raw_sessions` | one row per homeowner session | mutable — `ended_at` arrives late |
| `service_requests` | one row per SR | mutable — `status` updated in place |
| `raw_pro_profiles` | one row per sp_id **per category** | mutable; sp_id is NOT unique |
| `raw_payments` | one row per payment transaction | mutable — `payment_status` updated (pending→completed, completed→refunded) |

### Dimension models (`models/dimension/`)

All dimensions use `materialized = incremental`, `incremental_strategy = merge`, 1-day lookback — except:

- **`dim_date`** — full table refresh; spine covers 2020-01-01 to 2035-12-31 via `dbt_utils.date_spine`. Extend the range here when needed.
- **`dim_pro`** — SCD Type 2 on `sp_id + category`. The raw source has one row per `sp_id + category`; always join downstream on **both** `sp_id + category_key` to avoid fan-out.
- **`dim_service_request`** — SCD Type 2 on `sr_id + updated_at`. Use `is_current = true` to get the current status.

SCD Type 2 `valid_to` / `is_current` updates for `dim_pro` and `dim_service_request` are implemented as post-hooks but are **commented out** in both model files — they need to be enabled for production SCD2 behavior.

### Fact models (`models/fact/`)

| Model | Grain | Incremental lookback | Depends on |
|---|---|---|---|
| `fct_booking_events` | first `booking_submitted` event per session | 14 days (late events) | `raw_events` |
| `fct_booking_funnel` | one row per service request (`sr_id`) | 1 day | `fct_booking_events`, `dim_service_request`, `dim_pro`, `dim_session`, `dim_category`, `dim_geography` |
| `fct_session_events` | one row per raw user event | 1 day | `raw_events`, `dim_session` |
| `fct_revenue` | one row per payment transaction (`payment_id`) | 1 day | `raw_payments`, `service_requests`, `dim_service_request`, `dim_pro`, `dim_category`, `dim_geography` |

### Surrogate keys

All surrogate keys use `SHA2(natural_key_parts joined with '|')`. Fact table surrogate keys are documented in `models/fact/_fct__models.yml`.

### Key metric: `booking_conversion_rate`

Defined in `models/semantic/booking_conversion_rate.md`. Base table is `fact.fct_booking_funnel`:

```sql
sum(is_converted) / count(distinct booking_key)
```

Critical guardrails documented there:
- `booking_key` must be unique in `fct_booking_funnel` — a `dim_pro` fan-out on `category_key` alone (not `sp_id + category_key`) is the main risk and is a P1 failure.
- Always query from `fct_booking_funnel`, not `raw.service_requests` — the raw table includes SRs with no booking event, changing the denominator.
- Do NOT group by `pro_key`, `market`, or `pro_is_active` without purpose-built de-duplication logic.

### Key metrics: Revenue

Defined in `models/semantic/revenue_metrics.md`. Base table is `fact.fct_revenue`:

- **`net_platform_revenue`** — Angi's P&L metric: `SUM(net_platform_revenue)`. Sign-aware (positive for completed, negative for refunds/chargebacks).
- **`net_pro_payout`** — what professionals earn after clawbacks.
- **`effective_take_rate`** — realized commission: `SUM(net_platform_revenue) / SUM(gross_amount WHERE completed)`.
- Never mix `fct_revenue` denominators with `fct_booking_funnel` — they have different grains and populations.
