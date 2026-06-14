"""
Generate and load sample data into the angi.raw schema tables:
raw_pro_profiles, raw_sessions, raw_events, service_requests.

Usage: python scripts/load_sample_data.py
Requires ~/.dbt/profiles.yml (angi_case_study.dev) for connection details.
"""

import os
import random
from datetime import datetime, timedelta

import snowflake.connector
import yaml

random.seed(42)

NOW = datetime(2026, 6, 13, 12, 0, 0)

CATEGORIES = ["plumbing", "electrical", "hvac", "painting", "landscaping"]
GEOGRAPHIES = ["new york", "boston", "chicago", "austin", "seattle"]
PAGE_TYPES = ["home", "search", "booking_form", "confirmation"]
SOURCE_FILE = "sample_data/load_sample_data.py"


def conn():
    conf = yaml.safe_load(open(os.path.expanduser("~/.dbt/profiles.yml")))["angi_case_study"]["outputs"]["dev"]
    return snowflake.connector.connect(
        account=conf["account"], user=conf["user"], password=conf["password"],
        role=conf["role"], warehouse=conf["warehouse"], database="angi", schema="raw",
    )


def gen_pro_profiles():
    rows = []
    for i in range(1, 16):
        sp_id = f"sp_{i:04d}"
        n_categories = random.choice([1, 1, 2])  # most pros serve one category
        cats = random.sample(CATEGORIES, n_categories)
        for cat in cats:
            updated_at = NOW - timedelta(days=random.randint(0, 25))
            rows.append({
                "sp_id": sp_id,
                "market": random.choice(GEOGRAPHIES),
                "category": cat,
                "is_active": random.random() > 0.15,
                "updated_at": updated_at,
                "source_file": SOURCE_FILE,
            })
    return rows


def gen_sessions(n=60):
    rows = []
    for i in range(1, n + 1):
        session_id = f"session_{i:05d}"
        started_at = NOW - timedelta(days=random.randint(0, 13), hours=random.randint(0, 23))
        has_clean_end = random.random() > 0.2
        ended_at = started_at + timedelta(minutes=random.randint(2, 45)) if has_clean_end else None
        updated_at = ended_at if ended_at else started_at
        rows.append({
            "session_id": session_id,
            "started_at": started_at,
            "ended_at": ended_at,
            "page_type": random.choice(PAGE_TYPES),
            "updated_at": updated_at,
        })
    return rows


def gen_events_and_srs(sessions, pro_profiles):
    # group available pros by category so each SR can be matched to a pro
    # who actually offers that category (sp_id + category -> pro_profiles grain)
    pros_by_category = {}
    for p in pro_profiles:
        pros_by_category.setdefault(p["category"], []).append(p["sp_id"])

    event_rows = []
    sr_rows = []
    event_seq = 1
    sr_seq = 1

    for sess in sessions:
        session_id = sess["session_id"]
        t = sess["started_at"]

        # every session starts with a pro_viewed or booking_started
        event_rows.append({
            "event_id": f"evt_{event_seq:06d}", "session_id": session_id,
            "event_type": "pro_viewed", "event_ts": t, "sr_id": None,
        })
        event_seq += 1

        # ~70% of sessions progress to booking_started
        if random.random() < 0.7:
            t2 = t + timedelta(minutes=random.randint(1, 5))
            event_rows.append({
                "event_id": f"evt_{event_seq:06d}", "session_id": session_id,
                "event_type": "booking_started", "event_ts": t2, "sr_id": None,
            })
            event_seq += 1

            # ~80% of those submit a booking -> creates a service request
            if random.random() < 0.8:
                t3 = t2 + timedelta(minutes=random.randint(1, 10))
                sr_id = f"sr_{sr_seq:05d}"
                sr_seq += 1

                event_rows.append({
                    "event_id": f"evt_{event_seq:06d}", "session_id": session_id,
                    "event_type": "booking_submitted", "event_ts": t3, "sr_id": sr_id,
                })
                event_seq += 1

                created_at = t3
                status = random.choices(
                    ["submitted", "matched", "completed", "cancelled"],
                    weights=[0.2, 0.2, 0.45, 0.15],
                )[0]
                if status == "submitted":
                    updated_at = created_at
                else:
                    updated_at = created_at + timedelta(hours=random.randint(1, 72))

                category = random.choice(CATEGORIES)
                sr_rows.append({
                    "sr_id": sr_id,
                    "created_at": created_at,
                    "status": status,
                    "category": category,
                    "geography": random.choice(GEOGRAPHIES),
                    "sp_id": random.choice(pros_by_category[category]),
                    "updated_at": updated_at,
                })

    return event_rows, sr_rows


def main():
    pro_profiles = gen_pro_profiles()
    sessions = gen_sessions()
    events, service_requests = gen_events_and_srs(sessions, pro_profiles)

    cur = conn().cursor()

    # idempotent: clear out any previous run before reloading
    for table in ["raw_pro_profiles", "raw_sessions", "raw_events", "service_requests"]:
        cur.execute(f"truncate table {table}")

    cur.executemany(
        """
        insert into raw_pro_profiles (sp_id, market, category, is_active, updated_at, _source_file)
        values (%(sp_id)s, %(market)s, %(category)s, %(is_active)s, %(updated_at)s, %(source_file)s)
        """,
        pro_profiles,
    )
    print(f"inserted {len(pro_profiles)} rows into raw_pro_profiles")

    for s in sessions:
        s["source_file"] = SOURCE_FILE
    cur.executemany(
        """
        insert into raw_sessions (session_id, started_at, ended_at, page_type, updated_at, _source_file)
        values (%(session_id)s, %(started_at)s, %(ended_at)s, %(page_type)s, %(updated_at)s, %(source_file)s)
        """,
        sessions,
    )
    print(f"inserted {len(sessions)} rows into raw_sessions")

    # PARSE_JSON is not allowed in a multi-row VALUES clause, so insert one row at a time
    for e in events:
        e["properties"] = f'{{"sr_id": "{e["sr_id"]}"}}' if e["sr_id"] else "{}"
        e["source_file"] = SOURCE_FILE
        cur.execute(
            """
            insert into raw_events (event_id, session_id, event_type, event_ts, properties, _source_file)
            select %(event_id)s, %(session_id)s, %(event_type)s, %(event_ts)s, parse_json(%(properties)s), %(source_file)s
            """,
            e,
        )
    print(f"inserted {len(events)} rows into raw_events")

    for s in service_requests:
        s["source_file"] = SOURCE_FILE
    cur.executemany(
        """
        insert into service_requests (sr_id, created_at, status, category, geography, sp_id, updated_at, _source_file)
        values (%(sr_id)s, %(created_at)s, %(status)s, %(category)s, %(geography)s, %(sp_id)s, %(updated_at)s, %(source_file)s)
        """,
        service_requests,
    )
    print(f"inserted {len(service_requests)} rows into service_requests")


if __name__ == "__main__":
    main()
