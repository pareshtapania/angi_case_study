{{
    config(
        materialized   = 'incremental',
        unique_key     = 'category_key',
        incremental_strategy = 'merge',
        cluster_by     = ['category_key']
    )
}}

-- =============================================================================
-- dim_category
-- Grain   : one row per unique service category
-- Strategy: daily incremental merge — picks up new categories as service
--           requests arrive with previously unseen category values
-- =============================================================================

with source as (

    select distinct
        category
    from {{ source('raw', 'service_requests') }}
    where category is not null

    {% if is_incremental() %}
        -- only process categories not yet in the dimension
        and category not in (
            select category from {{ this }}
        )
    {% endif %}

),

final as (

    select

        -- surrogate key
        sha2(category)                              as category_key,

        -- natural key
        category,

        -- enrichment attributes (populate from reference seed when available)
        null::varchar                               as vertical,
        false                                       as is_seasonal,
        null::numeric                               as avg_ticket_usd,
        null::boolean                               as license_required,

        -- metadata
        current_timestamp()                         as dw_updated_at

    from source

)

select * from final
