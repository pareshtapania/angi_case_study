{{
    config(
        materialized   = 'incremental',
        unique_key     = 'booking_event_key',
        incremental_strategy = 'merge',
        cluster_by     = ['event_date']
    )
}}

-- =============================================================================
-- fact_booking_events
-- Grain   : one row per booking_submitted event per session (first only)
-- Strategy: daily incremental merge on booking_event_key
--           14-day lookback on event_ts to catch late-arriving events
-- Purpose : dedicated fact table for booking submission events only;
--           consumed by fct_booking_funnel; also queryable standalone
--           for booking volume and entry-point analytics
-- =============================================================================

with

raw_events as (

    select
        event_id,
        session_id,
        event_ts,
        properties:sr_id::varchar                   as sr_id

    from {{ source('raw', 'raw_events') }}

    where event_type = 'booking_submitted'
        and properties:sr_id::varchar is not null   -- guard: drop events with no sr_id

    {% if is_incremental() %}
        -- 14-day lookback: wider than 1 day to catch any late-arriving events
        and event_ts >= dateadd('day', -14, current_date)
    {% endif %}

),

-- deduplicate to the chronologically first booking_submitted per session
-- using ROW_NUMBER on event_ts ASC — never MIN() on varchar sr_id
ranked as (

    select
        event_id,
        session_id,
        sr_id,
        event_ts                                    as first_booking_ts,
        to_char(event_ts, 'YYYYMMDD')               as event_date,
        row_number() over (
            partition by session_id
            order by event_ts asc
        )                                           as event_rank

    from raw_events

),

first_per_session as (

    select
        event_id,
        session_id,
        sr_id,
        first_booking_ts,
        event_date
    from ranked
    where event_rank = 1

),

final as (

    select

        -- surrogate key: SHA2(session_id | sr_id)
        -- One session can have multiple booking events, but each booking event has one session,
        -- so session_id is not unique on its own; sr_id is needed to disambiguate multiple bookings
        -- in same session
        sha2(
            coalesce(session_id, 'null') || '|' ||
            coalesce(sr_id,      'null')
        )                                           as booking_event_key,

        -- natural keys retained for convenience
        session_id,
        sr_id,

        -- event timing
        first_booking_ts,
        event_date,                                 -- char(8) YYYYMMDD; FK to dim_date

        -- metadata
        current_timestamp()                         as dw_updated_at

    from first_per_session

)

select * from final
