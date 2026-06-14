{{
    config(
        materialized   = 'incremental',
        unique_key     = 'booking_key',
        incremental_strategy = 'merge',
        cluster_by     = ['created_at_date_key', 'category_key']
    )
}}

-- =============================================================================
-- fct_booking_funnel
-- Grain   : one row per service request (booking attempt)
-- Strategy: daily incremental merge on booking_key (= sr_id)
--           Dual lookback:
--             (a) 14-day on fact_booking_events for new booking events
--             (b) 1-day on service_requests.updated_at for late status changes
--           Both windows needed: (a) catches new bookings, (b) catches
--           existing bookings whose SR status flipped to completed/cancelled
--           after the event window closed
-- =============================================================================

with

-- ── Step 1: booking events (from fact_booking_events) ────────────────────────
booking_events as (

    select
        booking_event_key,
        session_id,
        sr_id,
        first_booking_ts,
        event_date
    from {{ ref('fct_booking_events') }}

    {% if is_incremental() %}
        where first_booking_ts >= dateadd('day', -14, current_date)
    {% endif %}

),

-- ── Step 2: service requests with FK resolution ───────────────────────────────
-- Also picks up SRs whose status changed recently (late completions/cancels)
-- even if their originating event is outside the 14-day window
service_requests as (

    select
        sr.sr_id,
        sr.created_at,
        sr.status,
        sr.updated_at,

        -- resolve category_key and geography_key
        dc.category_key,
        dg.geography_key,

        -- status flags
        iff(sr.status = 'completed', 1, 0)          as is_completed,
        iff(sr.status = 'cancelled', 1, 0)          as is_cancelled,
        iff(sr.status in ('matched','completed'),
            1, 0)                                   as is_matched,

        -- SCD Type 2: current version of dim_service_request
        dsr.service_request_key

    from {{ source('raw', 'service_requests') }} sr
    left join {{ ref('dim_category') }}         dc  on sr.category  = dc.category
    left join {{ ref('dim_geography') }}        dg  on sr.geography = dg.geography
    left join {{ ref('dim_service_request') }}  dsr
        on sr.sr_id = dsr.sr_id
        and dsr.is_current = true

    {% if is_incremental() %}
    where
        -- new bookings in scope
        sr.sr_id in (select sr_id from booking_events)
        -- OR status changed recently (catches late completions)
        or sr.updated_at >= dateadd('day', -1, current_date)
    {% endif %}

),

-- ── Step 3: sessions ──────────────────────────────────────────────────────────
sessions as (

    select
        session_id,
        session_id                                  as session_key,
        started_at                                  as session_started_at
    from {{ ref('dim_session') }}

),

-- ── Step 4: pro profiles (current version only) ───────────────────────────────
pro_profiles as (

    select
        sp_id,
        category_key,
        market,
        is_active,
        pro_key
    from {{ ref('dim_pro') }}
    where is_current = true

),

-- ── Step 5: status transition timestamps ─────────────────────────────────────
-- Using updated_at as proxy for transition time until a status_history
-- table is available for precise per-transition timestamps
status_timestamps as (

    select
        sr_id,
        iff(status in ('matched','completed'),
            updated_at, null)                       as matched_at,
        iff(status = 'completed',
            updated_at, null)                       as completed_at
    from {{ source('raw', 'service_requests') }}

),

-- ── Step 6: final assembly ────────────────────────────────────────────────────
final as (

    select

        -- ── Surrogate + natural key ───────────────────────────────────────────
        -- booking_key = sr_id per updated schema definition
        sr.sr_id                                    as booking_key,
        sr.sr_id,

        -- ── Foreign keys ─────────────────────────────────────────────────────
        coalesce(s.session_key, 'unknown')          as session_key,
        sr.service_request_key,
        pp.pro_key,
        to_char(sr.created_at, 'YYYYMMDD')          as created_at_date_key,
        sr.geography_key,
        sr.category_key,

        -- ── Timestamps ───────────────────────────────────────────────────────
        s.session_started_at,
        be.first_booking_ts,

        -- ── Status flags ─────────────────────────────────────────────────────
        coalesce(sr.is_completed, 0)                as is_converted,
        coalesce(sr.is_cancelled, 0)                as is_cancelled,
        coalesce(sr.is_matched,   0)                as is_matched,

        -- ── Duration metrics (future — nulled until status_history available) ─
        null::integer                               as session_to_booking_sec,
        null::integer                               as booking_to_match_sec,
        null::integer                               as match_to_complete_sec,

        -- ── Pro context (denormalized) ────────────────────────────────────────
        pp.market,
        pp.is_active                                as pro_is_active,

        -- ── Metadata ─────────────────────────────────────────────────────────
        current_timestamp()                         as dw_updated_at

    from booking_events be
    inner join service_requests sr
        on be.sr_id = sr.sr_id
    left join sessions s
        on be.session_id = s.session_id
    left join pro_profiles pp
        on sr.category_key = pp.category_key       -- join via category_key (no sp_id on SR)
    -- status_timestamps for future duration calculation
    left join status_timestamps st
        on sr.sr_id = st.sr_id

)

select * from final
