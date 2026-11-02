from hashlib import sha256

from fastapi import HTTPException
from sqlalchemy import select

from app.models import Membership, SessionToken, utc_now


def authenticate(db, authorization):
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(
            401, "Нужна действующая сессия", headers={"WWW-Authenticate": "Bearer"}
        )
    token = authorization[7:]
    if not token or len(token) > 512:
        raise HTTPException(401, "Недействующая сессия")
    membership = db.scalar(
        select(Membership)
        .join(SessionToken, SessionToken.user_id == Membership.user_id)
        .where(
            SessionToken.token_hash == sha256(token.encode()).hexdigest(),
            SessionToken.expires_at > utc_now(),
        )
    )
    if membership is None:
        raise HTTPException(401, "Недействующая сессия")
    return membership


def require_group(member, group_id, admin=False):
    if member.group_id != group_id or (admin and member.role not in ("admin", "owner")):
        raise HTTPException(403, "Недостаточно прав")
