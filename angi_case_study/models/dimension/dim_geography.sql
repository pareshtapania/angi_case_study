{{
    config(
        materialized   = 'incremental',
        unique_key     = 'geography_key',
        incremental_strategy = 'merge',
        cluster_by     = ['geography_key']
    )
}}

-- =============================================================================
-- dim_geography
-- Grain   : one row per unique geography string
-- Strategy: daily incremental merge — picks up new geography values as new
--           service requests arrive with previously unseen geographies
-- Note    : city/state/region/market_tier are enrichment fields; populate via
--           a reference seed or external lookup table when available
-- =============================================================================

with source as (

    select distinct
        geography
    from {{ source('raw', 'service_requests') }}
    where geography is not null

    {% if is_incremental() %}
        -- only process geographies not yet in the dimension
        and geography not in (
            select geography from {{ this }}
        )
    {% endif %}

),

final as (

    select

        -- surrogate key: SHA2 of the natural key
        sha2(geography)                             as geography_key,

        -- natural key
        geography,

        -- enrichment attributes (populate from reference table when available)
        null::varchar                               as city,
        null::varchar                               as state,
        null::char                                  as state_code,
        null::varchar                               as region,
        null::varchar                               as market_tier,

        -- future geo attributes
        null::varchar                               as dma_code,
        null::varchar                               as dma_name,
        null::numeric                               as latitude,
        null::numeric                               as longitude,

        -- metadata
        current_timestamp()                         as dw_updated_at

    from source

)

select * from final
