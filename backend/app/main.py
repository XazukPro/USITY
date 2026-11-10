"""Uvicorn factory: requires an explicit database URL; never seeds real data."""

import os

from app.api import create_app


def factory():
    url = os.environ.get("USITY_DATABASE_URL")
    if not url:
        raise RuntimeError("Задайте USITY_DATABASE_URL")
    return create_app(url)
