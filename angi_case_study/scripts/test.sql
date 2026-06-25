-- Incremental model, filtered on event_ts
-- Runs nightly; incremental filter: event_ts >= dateadd('day', -3, current_date)

with booking_events as (
    select
        session_id,
        min(case when event_type = 'booking_submitted' then event_ts end) as first_booking_ts,
        min(properties:sr_id::varchar)                                    as sr_id
    from raw_events
    where event_type = 'booking_submitted'
    group by session_id   
),

sessions as (
    select * from raw_sessions
),

service_requests as (
    select * from service_requests
),

pro_profiles as (
    select * from raw_pro_profiles
)

select
    s.session_id,
    be.sr_id,
    s.started_at,
    be.first_booking_ts,
    sr.status,
    sr.category,
    sr.geography,
    pp.market,
    pp.is_active,
    case when sr.status = 'completed' then 1 else 0 end as is_converted
from sessions s
left join booking_events be on s.session_id = be.session_id
left join service_requests sr on be.sr_id = sr.sr_id
left join pro_profiles pp on sr.sp_id = pp.sp_id  
 
