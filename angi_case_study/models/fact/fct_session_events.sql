{{
    config(
        materialized   = 'incremental',
        unique_key     = 'event_key',
        incremental_strategy = 'merge',
        cluster_by     = ['event_date_key']
    )
}}

-- =============================================================================
-- fct_session_events
-- Grain   : one row per raw user event
-- Strategy: daily incremental merge on event_key
--           1-day lookback on event_ts — events are immutable once fired;
--           no late-arriving updates expected (unlike SRs)
--           +1 day buffer handles timezone edge cases
-- =============================================================================

with

source as (

    select
        event_id,
        session_id,
        event_type,
        event_ts,
        properties:sr_id::varchar                   as properties_sr_id

    from {{ source('raw', 'raw_events') }}

    {% if is_incremental() %}
        where event_ts >= dateadd('day', -1, current_date)
    {% endif %}

),

sessions as (

    select
        session_id,
        session_id                                  as session_key,
        started_at                                  as session_started_at,
        ended_at                                    as session_ended_at,
        session_duration_sec,
        page_type,
        is_clean_end
    from {{ ref('dim_session') }}

    {% if is_incremental() %}
        where updated_at >= dateadd('day', -1, current_date)
    {% endif %}

),

-- ── Session-level aggregates (computed once, joined back) ────────────────
session_aggs as (

    select
        session_id,
        count(*)                                    as session_event_count,
        sum(iff(event_type = 'booking_started',   1, 0)) as session_booking_started_count,
        sum(iff(event_type = 'booking_submitted', 1, 0)) as session_booking_submitted_count,
        sum(iff(event_type = 'pro_viewed',        1, 0)) as session_pro_viewed_count,
        max(iff(event_type = 'booking_submitted', 1, 0)) as session_has_booking
    from source
    group by session_id

),

-- ── Event sequencing via window functions ─────────────────────────────────
sequenced as (

    select
        e.*,

        row_number() over (
            partition by e.session_id
            order by e.event_ts asc
        )                                           as event_sequence_number,

        lag(e.event_ts) over (
            partition by e.session_id
            order by e.event_ts asc
        )                                           as prev_event_ts,

        min(e.event_ts) over (
            partition by e.session_id
        )                                           as session_first_event_ts,

        max(e.event_ts) over (
            partition by e.session_id
        )                                           as session_last_event_ts

    from source e

),

final as (

    select

        -- ── Surrogate key ─────────────────────────────────────────────────────
        sha2(
            coalesce(sq.event_id,   'null') || '|' ||
            coalesce(sq.session_id, 'null') || '|' ||
            coalesce(sq.event_ts::varchar, 'null')
        )                                           as event_key,

        -- ── Denormalized natural key ──────────────────────────────────────────
        sq.event_id,

        -- ── Foreign keys ─────────────────────────────────────────────────────
        coalesce(s.session_key, sq.session_id)      as session_key,

        -- ── Event attributes ──────────────────────────────────────────────────
        sq.event_type,
        sq.event_ts,
        to_date(sq.event_ts)                        as event_date_key,
        sq.properties_sr_id,

        -- ══════════════════════════════════════════════════════════════════════
        -- SITE-LEVEL METRICS
        -- Aggregatable across all events/sessions for overall site performance
        -- ══════════════════════════════════════════════════════════════════════

        s.session_started_at,
        s.session_ended_at,
        s.session_duration_sec,
        s.is_clean_end,
        sa.session_event_count,
        iff(sa.session_event_count = 1, 1, 0)       as is_bounce_session,
        datediff('second',
            s.session_started_at,
            sq.event_ts)                             as seconds_since_session_start,

        -- ══════════════════════════════════════════════════════════════════════
        -- PAGE-LEVEL METRICS
        -- Page type at session start; boolean flags for easy filtering/grouping
        -- ══════════════════════════════════════════════════════════════════════

        s.page_type,
        iff(s.page_type = 'home',             1, 0) as is_home_page,
        iff(s.page_type = 'search',           1, 0) as is_search_page,
        iff(s.page_type = 'booking_form',     1, 0) as is_booking_form_page,
        iff(s.page_type = 'confirmation',     1, 0) as is_confirmation_page,

        -- ══════════════════════════════════════════════════════════════════════
        -- EVENT-SPECIFIC METRICS
        -- Per-event sequencing, timing, and classification
        -- ══════════════════════════════════════════════════════════════════════

        sq.event_sequence_number,
        iff(sq.event_ts = sq.session_first_event_ts, 1, 0) as is_first_event_in_session,
        iff(sq.event_ts = sq.session_last_event_ts,  1, 0) as is_last_event_in_session,

        datediff('second',
            sq.prev_event_ts,
            sq.event_ts)                             as seconds_since_prev_event,

        iff(sq.properties_sr_id is not null, 1, 0)   as has_sr_id,

        -- ── Additive boolean flags ────────────────────────────────────────────
        iff(sq.event_type = 'booking_started',    1, 0)  as is_booking_started,
        iff(sq.event_type = 'booking_submitted',  1, 0)  as is_booking_submitted,
        iff(sq.event_type = 'pro_viewed',         1, 0)  as is_pro_viewed,

        -- ── Session-level event counts (denormalized) ─────────────────────────
        sa.session_booking_started_count,
        sa.session_booking_submitted_count,
        sa.session_pro_viewed_count,
        sa.session_has_booking                       as session_has_booking_submitted,

        -- ── Metadata ─────────────────────────────────────────────────────────
        current_timestamp()                         as dw_updated_at

    from sequenced sq
    left join sessions s
        on sq.session_id = s.session_id
    left join session_aggs sa
        on sq.session_id = sa.session_id

)

select * from final
