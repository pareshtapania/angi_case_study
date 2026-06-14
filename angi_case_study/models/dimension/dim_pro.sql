{{
    config(
        materialized   = 'incremental',
        unique_key     = 'pro_key',
        incremental_strategy = 'merge',
        cluster_by     = ['sp_id']
    )
}}

-- =============================================================================
-- dim_pro
-- Grain   : one row per sp_id + category version (SCD Type 2)
--           sp_id + category_key uniquely identify a pro in this model
-- Strategy: daily incremental merge on pro_key
--           Detects is_active changes via raw_pro_profiles.updated_at
-- =============================================================================

with source as (

    select
        pp.sp_id,
        pp.category,
        pp.market,
        pp.is_active,
        pp.updated_at,

        -- resolve category FK
        sha2(pp.category)                            as category_key,

        -- derive first/last active timestamps across all profiles for this pro
        min(pp.updated_at) over (
            partition by pp.sp_id
        )                                           as first_active_at,
        max(pp.updated_at) over (
            partition by pp.sp_id
        )                                           as last_active_at,

        -- deduplicate: one row per sp_id + category (latest updated_at wins)
        row_number() over (
            partition by pp.sp_id, pp.category
            order by pp.updated_at desc nulls last
        )                                           as profile_rank

    from {{ source('raw', 'raw_pro_profiles') }} pp

    {% if is_incremental() %}
        where pp.updated_at >= dateadd('day', -1, current_date)
    {% endif %}

),

-- keep only the most recent profile per sp_id + category
deduped as (

    select * from source
    where profile_rank = 1

),

final as (

    select

        -- surrogate key: SHA2(sp_id + category + updated_at) for SCD versioning
        sha2(
            d.sp_id     || '|' ||
            d.category  || '|' ||
            coalesce(d.updated_at::varchar, 'null')
        )                                           as pro_key,

        -- natural key
        d.sp_id,

        -- FK to dim_category
        d.category_key,

        -- pro attributes
        d.market,
        d.is_active,
        d.first_active_at,
        d.last_active_at,

        -- future enrichment
        null::varchar                               as tier,
        null::numeric                               as rating,
        null::integer                               as review_count,

        -- SCD Type 2 columns
        d.updated_at                                as valid_from,
        null::timestamp_ntz                         as valid_to,
        true                                        as is_current,

        -- metadata
        current_timestamp()                         as dw_updated_at

    from deduped d

)

select * from final

-- =============================================================================
-- POST-HOOK: close previous current records for changed pros (same pattern
-- as dim_service_request — update valid_to and is_current on the old record)
-- =============================================================================
-- post_hook:
--   "update {{ this.schema }}.dim_pro old
--    set    old.valid_to   = new.valid_from,
--           old.is_current = false
--    from   {{ this.schema }}.dim_pro new
--    where  old.sp_id       = new.sp_id
--    and    old.category_key = new.category_key
--    and    old.is_current  = true
--    and    new.is_current  = true
--    and    old.pro_key    != new.pro_key"
