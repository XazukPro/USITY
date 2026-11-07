"""Apply versioned USITY schema upgrades, atomically, to SQLite or PostgreSQL."""

import os
from pathlib import Path

from sqlalchemy import text

from app.db import make_engine


def migrate(url):
    engine = make_engine(url)
    try:
        with engine.begin() as conn:
            if engine.dialect.name == "postgresql":
                conn.execute(text("SELECT pg_advisory_xact_lock(838779)"))
            conn.exec_driver_sql(
                "CREATE TABLE IF NOT EXISTS usity_schema (version VARCHAR(32) PRIMARY KEY)"
            )
            applied = set(
                conn.execute(text("SELECT version FROM usity_schema")).scalars()
            )
            for path in sorted(Path(__file__).with_name("migrations").glob("*.sql")):
                if path.stem in applied:
                    continue
                for statement in path.read_text().split(";"):
                    if statement.strip():
                        conn.exec_driver_sql(statement)
                conn.execute(
                    text("INSERT INTO usity_schema(version) VALUES (:version)"),
                    {"version": path.stem},
                )
    finally:
        engine.dispose()


if __name__ == "__main__":
    migrate(os.environ["USITY_DATABASE_URL"])
