{{
    config(
        materialized='table'
    )
}}

-- =============================================================================
-- dim_date
-- Grain   : one row per calendar date
-- Strategy: full table — truncate and reload; never incremental
--           Extend the date range below when the spine needs updating
-- =============================================================================

with date_spine as (

    {{ dbt_utils.date_spine(
        datepart   = "day",
        start_date = "cast('2020-01-01' as date)",
        end_date   = "cast('2035-12-31' as date)"
    ) }}

),

final as (

    select

        -- surrogate key
        to_char(date_day, 'YYYYMMDD')               as date_key,

        -- date attributes
        date_day                                    as full_date,
        year(date_day)                              as year,
        quarter(date_day)                           as quarter,
        month(date_day)                             as month,
        monthname(date_day)                         as month_name,
        weekiso(date_day)                           as week,
        dayname(date_day)                           as day_of_week,
        dayofweekiso(date_day)                      as day_of_week_num,
        iff(dayofweekiso(date_day) in (6,7),
            true, false)                            as is_weekend,

        -- holiday flag: seed-driven; defaulting false until seed loaded
        false                                       as is_holiday,

        -- fiscal placeholders (populate when fiscal calendar is defined)
        null::smallint                              as fiscal_year,
        null::smallint                              as fiscal_quarter,
        null::varchar                               as fiscal_period,

        -- metadata
        current_timestamp()                         as dw_updated_at

    from date_spine

)

select * from final
