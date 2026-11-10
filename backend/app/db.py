from datetime import UTC

from sqlalchemy import DateTime, create_engine, event
from sqlalchemy.orm import DeclarativeBase
from sqlalchemy.types import TypeDecorator


class Base(DeclarativeBase):
    pass


class UTCDateTime(TypeDecorator):
    """Keep API timestamps aware even when the local SQLite driver drops tzinfo."""

    impl = DateTime(timezone=True)
    cache_ok = True

    def process_bind_param(self, value, dialect):
        if value is None:
            return None
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("Timezone required")
        return value.astimezone(UTC)

    def process_result_value(self, value, dialect):
        if value is None:
            return None
        return (
            value.replace(tzinfo=UTC) if value.tzinfo is None else value.astimezone(UTC)
        )


def make_engine(url):
    engine = create_engine(
        url,
        connect_args={"check_same_thread": False, "timeout": 15}
        if url.startswith("sqlite")
        else {},
        pool_pre_ping=True,
    )
    if engine.dialect.name == "sqlite":

        @event.listens_for(engine, "connect")
        def enable_foreign_keys(connection, _):
            connection.isolation_level = None
            connection.execute("PRAGMA foreign_keys=ON")

        @event.listens_for(engine, "begin")
        def begin_serialized(connection):
            # Local SQLite has no row locks. Reserve the write lock before any
            # authorization/version/source read that will precede a write.
            connection.exec_driver_sql("BEGIN IMMEDIATE")

    return engine
