{{
    config(
        materialized   = 'incremental',
        unique_key     = 'revenue_key',
        incremental_strategy = 'merge',
        cluster_by     = ['payment_date_key', 'category_key']
    )
}}

-- =============================================================================
-- fct_revenue
-- Grain   : one row per payment transaction (payment_id)
-- Strategy: daily incremental merge on revenue_key, 1-day lookback on
--           raw_payments.updated_at to catch late status changes (e.g.
--           pending -> completed, completed -> refunded).
-- Purpose : tracks gross revenue, platform commission (Angi take), and
--           pro payout for every payment tied to a service request.
-- =============================================================================

with

-- ── Step 1: payments with FK resolution ──────────────────────────────────────
payments as (

    select
        p.payment_id,
        p.sr_id,
        p.payment_ts,
        p.payment_method,
        p.payment_status,
        p.gross_amount,
        p.commission_rate,
        p.commission_amount,
        p.pro_payout_amount,
        p.updated_at,

        -- resolve dimension keys from service_requests
        sr.sp_id,
        sr.category,
        sr.geography,

        dc.category_key,
        dg.geography_key

    from {{ source('raw', 'raw_payments') }} p
    inner join {{ source('raw', 'service_requests') }} sr
        on p.sr_id = sr.sr_id
    left join {{ ref('dim_category') }}  dc on sr.category  = dc.category
    left join {{ ref('dim_geography') }} dg on sr.geography = dg.geography

    {% if is_incremental() %}
    where p.updated_at >= dateadd('day', -1, current_date)
    {% endif %}

),

-- ── Step 2: pro profiles (current version only) ─────────────────────────────
pro_profiles as (

    select
        sp_id,
        category_key,
        pro_key,
        market,
        is_active
    from {{ ref('dim_pro') }}
    where is_current = true

),

-- ── Step 3: service request dimension (current version) ─────────────────────
service_requests_dim as (

    select
        sr_id,
        service_request_key,
        status          as sr_status,
        is_completed,
        is_cancelled
    from {{ ref('dim_service_request') }}
    where is_current = true

),

-- ── Step 4: final assembly ──────────────────────────────────────────────────
final as (

    select

        -- ── Surrogate key ────────────────────────────────────────────────────
        sha2(pay.payment_id)                            as revenue_key,

        -- ── Natural keys ─────────────────────────────────────────────────────
        pay.payment_id,
        pay.sr_id,

        -- ── Foreign keys ─────────────────────────────────────────────────────
        srd.service_request_key,
        pay.sp_id,
        pp.pro_key,
        to_char(pay.payment_ts, 'YYYYMMDD')             as payment_date_key,
        pay.category_key,
        pay.geography_key,

        -- ── Payment attributes ───────────────────────────────────────────────
        pay.payment_ts,
        pay.payment_method,
        pay.payment_status,

        -- ── Revenue amounts (USD) ────────────────────────────────────────────
        pay.gross_amount,
        pay.commission_rate,
        pay.commission_amount                           as platform_commission,
        pay.pro_payout_amount,

        -- ── Derived revenue flags ────────────────────────────────────────────
        iff(pay.payment_status = 'completed', 1, 0)    as is_settled,
        iff(pay.payment_status = 'refunded',  1, 0)    as is_refunded,
        iff(pay.payment_status = 'chargeback', 1, 0)   as is_chargeback,
        iff(pay.payment_status = 'pending',   1, 0)    as is_pending,

        -- ── Net revenue (zero for non-settled payments) ──────────────────────
        case
            when pay.payment_status = 'completed'
                then pay.commission_amount
            when pay.payment_status in ('refunded', 'chargeback')
                then -1 * pay.commission_amount
            else 0
        end                                             as net_platform_revenue,

        case
            when pay.payment_status = 'completed'
                then pay.pro_payout_amount
            when pay.payment_status in ('refunded', 'chargeback')
                then -1 * pay.pro_payout_amount
            else 0
        end                                             as net_pro_payout,

        -- ── SR context (denormalized) ────────────────────────────────────────
        srd.sr_status,
        coalesce(srd.is_completed, false)               as sr_is_completed,

        -- ── Pro context (denormalized) ───────────────────────────────────────
        pp.market,
        pp.is_active                                    as pro_is_active,

        -- ── Metadata ─────────────────────────────────────────────────────────
        current_timestamp()                             as dw_updated_at

    from payments pay
    left join service_requests_dim srd
        on pay.sr_id = srd.sr_id
    left join pro_profiles pp
        on pay.sp_id       = pp.sp_id
        and pay.category_key = pp.category_key
)

select * from final
