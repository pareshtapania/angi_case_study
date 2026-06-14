{{
    config(
        materialized   = 'incremental',
        unique_key     = 'session_key',
        incremental_strategy = 'merge',
        cluster_by     = ['session_key']
    )
}}

-- =============================================================================
-- dim_session
-- Grain   : one row per session
-- Strategy: daily incremental merge on session_key
--           Picks up new sessions and sessions updated (ended_at populated late)
--           via raw_sessions.updated_at
-- =============================================================================

with source as (

    select
        session_id,
        started_at,
        ended_at,
        page_type,
        updated_at
    from {{ source('raw', 'raw_sessions') }}

    {% if is_incremental() %}
        -- daily incremental: re-process sessions updated in last 1 day
        -- +1 day buffer catches any timezone edge cases at midnight
        where updated_at >= dateadd('day', -1, current_date)
    {% endif %}

),

final as (

    select

        -- surrogate key (session_id is stable; using directly as surrogate)
        s.session_id                                as session_key,

        -- natural key
        s.session_id,

        -- session attributes
        s.started_at,
        s.ended_at,
        datediff('second',
            s.started_at,
            s.ended_at)                             as session_duration_sec,

        -- page type at session start (raw_events carries no page_type to aggregate)
        s.page_type,

        -- is_clean_end: true only when ended_at is populated
        iff(s.ended_at is not null, true, false)    as is_clean_end,

        -- metadata
        current_timestamp()                         as dw_updated_at

    from source s

)

select * from final
