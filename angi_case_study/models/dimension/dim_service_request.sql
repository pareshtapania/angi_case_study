{{
    config(
        materialized   = 'incremental',
        unique_key     = 'service_request_key',
        incremental_strategy = 'merge',
        cluster_by     = ['sr_id']
    )
}}

-- =============================================================================
-- dim_service_request
-- Grain   : one row per sr_id per status version (SCD Type 2)
-- Strategy: daily incremental merge on service_request_key (sr_id + valid_from)
--           Detects status changes via raw.service_requests.updated_at
--           Each status change closes the previous record (valid_to = now)
--           and inserts a new current record (is_current = true)
-- =============================================================================

with source as (

    select
        sr.sr_id,
        sr.created_at,
        sr.status,
        sr.category,
        sr.geography,
        sr.updated_at,

        -- resolve category_key and geography_key from dimensions
        dc.category_key,
        dg.geography_key,

        -- derive status flags
        iff(sr.status = 'completed', true, false)   as is_completed,
        iff(sr.status = 'cancelled', true, false)   as is_cancelled

    from {{ source('raw', 'service_requests') }} sr
    left join {{ ref('dim_category') }}  dc on sr.category  = dc.category
    left join {{ ref('dim_geography') }} dg on sr.geography = dg.geography

    {% if is_incremental() %}
        -- daily incremental: re-process SRs updated in last 1 day
        -- wider buffer also catches late-arriving status changes
        where sr.updated_at >= dateadd('day', -1, current_date)
    {% endif %}

)

{% if is_incremental() %}
-- SCD Type 2: close existing current records whose status has changed
, existing_current as (

    select
        t.service_request_key,
        t.sr_id,
        t.status                                    as existing_status,
        s.status                                    as incoming_status,
        iff(t.status != s.status, true, false)      as status_changed
    from {{ this }} t
    inner join source s
        on t.sr_id = s.sr_id
        and t.is_current = true

)
{% endif %}

-- build the final record set: new/updated records
, final as (

    select

        -- surrogate key: SHA2(sr_id + valid_from timestamp) ensures uniqueness
        -- across SCD versions
        sha2(s.sr_id || '|' || s.updated_at::varchar)   as service_request_key,

        -- natural key
        s.sr_id,

        -- SR attributes
        s.created_at,
        s.status,

        -- FK keys (replaces raw category/geography strings)
        s.category_key,
        s.geography_key,

        -- status flags
        s.is_completed,
        s.is_cancelled,

        -- future FK
        null::varchar                               as homeowner_key,

        -- SCD Type 2 columns
        s.updated_at                                as valid_from,
        null::timestamp_ntz                         as valid_to,       -- current record
        true                                        as is_current,

        -- metadata
        current_timestamp()                         as dw_updated_at

    from source s

    {% if is_incremental() %}
    -- only insert where status has actually changed or record is new
    where s.sr_id not in (
        select sr_id from existing_current where status_changed = false
    )
    {% endif %}

)

select * from final

-- =============================================================================
-- POST-HOOK: close previous current records when a new version is inserted
-- In a full dbt SCD2 implementation this would use the dbt_utils
-- surrogate_key + snapshot approach. Shown here as an explicit merge pattern.
-- =============================================================================
-- post_hook:
--   "update {{ this.schema }}.dim_service_request old
--    set    old.valid_to     = new.valid_from,
--           old.is_current   = false
--    from   {{ this.schema }}.dim_service_request new
--    where  old.sr_id        = new.sr_id
--    and    old.is_current   = true
--    and    new.is_current   = true
--    and    old.service_request_key != new.service_request_key"
