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
        -- daily incremental: 1-day lookback + 1-day buffer
        where event_ts >= dateadd('day', -1, current_date)
    {% endif %}

),

sessions as (

    select
        session_id,
        session_id                                  as session_key
    from {{ ref('dim_session') }}

    {% if is_incremental() %}
        -- daily incremental: 1-day lookback + 1-day buffer
        where updated_at >= dateadd('day', -1, current_date)
    {% endif %}

),

final as (

    select

        -- ── Surrogate key ─────────────────────────────────────────────────────
        sha2(
            coalesce(e.event_id,   'null') || '|' ||
            coalesce(e.session_id, 'null') || '|' ||
            coalesce(e.event_ts::varchar, 'null')
        )                                           as event_key,

        -- ── Denormalized natural key ──────────────────────────────────────────
        e.event_id,

        -- ── Foreign keys ─────────────────────────────────────────────────────
        coalesce(s.session_key, e.session_id)       as session_key,

        -- ── Event attributes ──────────────────────────────────────────────────
        e.event_type,
        e.event_ts,

        -- event_date_key: type date
        to_date(e.event_ts)                         as event_date_key,

        e.properties_sr_id,

        -- ── Additive boolean flags ────────────────────────────────────────────
        iff(e.event_type = 'booking_started',    1, 0)  as is_booking_started,
        iff(e.event_type = 'booking_submitted',  1, 0)  as is_booking_submitted,
        iff(e.event_type = 'pro_viewed',         1, 0)  as is_pro_viewed,

        -- ── Metadata ─────────────────────────────────────────────────────────
        current_timestamp()                         as dw_updated_at

    from source e
    left join sessions s
        on e.session_id = s.session_id

)

select * from final
