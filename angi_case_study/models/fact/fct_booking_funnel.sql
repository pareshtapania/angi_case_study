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
-- Strategy: daily incremental merge on booking_key (= sr_id), 1-day lookback.
--           A service request is in scope for an incremental run if any of:
--             (a) its fct_booking_events row was created in the last 1 day
--             (b) raw.service_requests.updated_at changed in the last 1 day
--             (c) its dim_service_request (current SCD2) row changed in the
--                 last 1 day
--           (b)/(c) catch late status changes (e.g. completed/cancelled)
--           on bookings whose original event is outside the 1-day window.
-- =============================================================================

with

-- ── Step 1: service requests with FK resolution ───────────────────────────────
service_requests as (

    select
        sr.sr_id,
        sr.created_at,
        sr.status,
        sr.updated_at,
        sr.sp_id,

        -- resolve category_key and geography_key
        dc.category_key,
        dg.geography_key,

        -- status flags
        iff(sr.status = 'completed', 1, 0)          as is_completed,
        iff(sr.status = 'cancelled', 1, 0)          as is_cancelled,
        iff(sr.status in ('matched','completed'),
            1, 0)                                   as is_matched,

        -- SCD Type 2: current version of dim_service_request
        dsr.service_request_key,
        dsr.valid_from                              as dsr_valid_from


    from {{ source('raw', 'service_requests') }} sr
    left join {{ ref('dim_category') }}         dc  on sr.category  = dc.category
    left join {{ ref('dim_geography') }}        dg  on sr.geography = dg.geography
    left join {{ ref('dim_service_request') }}  dsr on sr.sr_id = dsr.sr_id


    {% if is_incremental() %}
    where
        sr.updated_at >= dateadd('day', -1, current_date)
        -- OR its dim_service_request record changed recently
        or dsr.valid_from >= dateadd('day', -1, current_date)
    {% endif %}

),

-- ── Step 2: sessions ──────────────────────────────────────────────────────────
sessions as (

    select
        session_id,
        session_id                                  as session_key,
        started_at                                  as session_started_at
    from {{ ref('dim_session') }}
    {% if is_incremental() %}
    where session_started_at >= dateadd('day', -1, current_date)
    {% endif %}


),

-- ── Step 3: pro profiles (current version only) ───────────────────────────────
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


-- ── Step 5: final assembly ────────────────────────────────────────────────────
final as (

    select

        -- ── Surrogate + natural key ───────────────────────────────────────────
        -- booking_key = sr_id per updated schema definition
        sr.sr_id                                    as booking_key,
        sr.sr_id,

        -- ── Foreign keys ─────────────────────────────────────────────────────
        coalesce(s.session_key, 'unknown')          as session_key,
        sr.service_request_key,
        sr.sp_id,
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

        -- ── Pro context (denormalized) ────────────────────────────────────────
        pp.market,
        pp.is_active                                as pro_is_active,

        -- ── Metadata ─────────────────────────────────────────────────────────
        current_timestamp()                         as dw_updated_at

    from service_requests sr
    inner join {{ ref('fct_booking_events') }} be
        on sr.sr_id = be.sr_id
        {% if is_incremental() %}
        and be.first_booking_ts >= dateadd('day', -1, current_date)
        {% endif %}
    left join sessions s
        on be.session_id = s.session_id
    left join pro_profiles pp
        on sr.sp_id = pp.sp_id
        and sr.category_key = pp.category_key       -- sp_id + category_key: 1:1, no fan-out


)

select * from final
