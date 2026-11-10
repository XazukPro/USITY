from hashlib import sha256

from fastapi import HTTPException
from sqlalchemy import select

from app.models import AccountSession, Membership, SessionToken, utc_now


def token_digest(authorization):
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(
            401, "Нужна действующая сессия", headers={"WWW-Authenticate": "Bearer"}
        )
    token = authorization[7:]
    if not token or len(token) > 512:
        raise HTTPException(401, "Недействующая сессия")
    return sha256(token.encode()).hexdigest()


def authenticate(db, authorization):
    digest = token_digest(authorization)
    membership = db.scalar(
        select(Membership)
        .join(SessionToken, SessionToken.user_id == Membership.user_id)
        .where(
            SessionToken.token_hash == digest,
            SessionToken.expires_at > utc_now(),
        )
    )
    if membership is None:
        membership = db.scalar(
            select(Membership)
            .join(AccountSession, AccountSession.user_id == Membership.user_id)
            .where(
                AccountSession.token_hash == digest,
                AccountSession.expires_at > utc_now(),
            )
        )
    if membership is None:
        raise HTTPException(401, "Недействующая сессия")
    return membership


def require_group(member, group_id, admin=False):
    if member.group_id != group_id or (admin and member.role not in ("admin", "owner")):
        raise HTTPException(403, "Недостаточно прав")
