import hmac
import re
import secrets
from typing import Annotated

from fastapi import Depends, Header, HTTPException, Request
from pydantic import Field, field_validator
from sqlalchemy import delete, select

from app.auth import token_digest
from app.group_access import SemesterInput, validated_choices
from app.mail_codes import send_code, verify_code
from app.models import (
    Account,
    AccountSession,
    GroupDetails,
    Membership,
    StudyGroup,
    SubjectChoice,
    utc_now,
)
from app.schemas import InputModel


class Address(InputModel):
    email: str = Field(max_length=254)

    @field_validator("email")
    @classmethod
    def normalize(cls, v):
        v = v.strip().lower()
        if not re.fullmatch(
            r"[a-z0-9_+%-]+(?:\.[a-z0-9_+%-]+)*@[a-z0-9-]+(?:\.[a-z0-9-]+)+", v
        ):
            raise ValueError("Некорректный email")
        return v


class Verify(Address):
    code: str = Field(pattern=r"^[0-9]{6}$")


class Join(InputModel):
    invite: str = Field(min_length=1, max_length=160)


class Choices(InputModel):
    choices: dict[str, int] = Field(max_length=80)


def install_accounts(app, DB, mail):
    def delivery():
        if mail is None:
            raise HTTPException(503, "Доставка кодов не настроена")
        return mail

    def identity(db: DB, authorization: Annotated[str | None, Header()] = None):
        session = db.get(AccountSession, token_digest(authorization))
        if session is None or session.expires_at <= utc_now():
            raise HTTPException(401, "Войдите снова")
        return session

    Identity = Annotated[AccountSession, Depends(identity)]

    def invite(details):
        raw = f"invite:{details.group_id}:{details.invite_nonce}"
        return details.group_id + "." + delivery().mac(raw)

    def profile(db, uid):
        member = db.get(Membership, uid)
        details = db.get(GroupDetails, member.group_id) if member else None
        return {
            "user_id": uid,
            "email": db.get(Account, uid).email,
            "group_id": member.group_id if member else None,
            "group_name": details.name if details else None,
            "role": member.role if member else None,
            "subjects": [
                {"name": s["name"], "groups": s["groups"]}
                for s in details.semester["subjects"]
                if s["groups"]
            ]
            if details
            else [],
            "choices": {
                s.subject: s.subgroup
                for s in db.scalars(
                    select(SubjectChoice).where(SubjectChoice.user_id == uid)
                )
            },
            "invite_url": "usity://join/" + invite(details)
            if details and member.role == "owner"
            else None,
        }

    def lock_free_account(db, uid):
        db.scalar(select(Account).where(Account.id == uid).with_for_update())
        if db.get(Membership, uid):
            raise HTTPException(409, "Вы уже состоите в группе")

    @app.post("/auth/code", status_code=202)
    def request_code(body: Address, req: Request, db: DB):
        send_code(
            db, delivery(), body.email, req.client.host if req.client else "unknown"
        )
        return {"sent": True}

    @app.post("/auth/verify")
    def verify(body: Verify, req: Request, db: DB):
        return {
            "token": verify_code(
                db,
                delivery(),
                body.email,
                body.code,
                req.client.host if req.client else "unknown",
            )
        }

    @app.get("/account")
    def account(db: DB, session: Identity):
        return profile(db, session.user_id)

    @app.post("/account/logout")
    def logout(db: DB, session: Identity):
        db.delete(session)
        db.commit()
        return {"ok": True}

    @app.post("/account/group", status_code=201)
    def create(body: SemesterInput, db: DB, session: Identity):
        delivery()
        uid = session.user_id
        lock_free_account(db, uid)
        group = StudyGroup()
        db.add(group)
        db.flush()
        db.add(
            GroupDetails(
                group_id=group.id,
                name=body.name,
                semester=body.model_dump(mode="json"),
                invite_nonce=secrets.token_hex(16),
            )
        )
        db.add(Membership(user_id=uid, group_id=group.id, role="owner"))
        body.publish(db, group.id)
        db.commit()
        return profile(db, uid)

    @app.post("/account/join")
    def join(body: Join, db: DB, session: Identity):
        uid = session.user_id
        lock_free_account(db, uid)
        gid = body.invite.partition(".")[0]
        details = db.get(GroupDetails, gid)
        if (
            not details
            or not body.invite.isascii()
            or not hmac.compare_digest(invite(details), body.invite)
        ):
            raise HTTPException(404, "Приглашение недействительно")
        db.add(Membership(user_id=uid, group_id=gid, role="student"))
        db.commit()
        return profile(db, uid)

    @app.put("/account/subgroups")
    def choose(body: Choices, db: DB, session: Identity):
        uid = session.user_id
        db.scalar(select(Account).where(Account.id == uid).with_for_update())
        member = db.get(Membership, uid)
        if member is None:
            raise HTTPException(409, "Сначала вступите в группу")
        details = db.get(GroupDetails, member.group_id)
        validated_choices(details.semester, body.choices)
        db.execute(delete(SubjectChoice).where(SubjectChoice.user_id == uid))
        db.add_all(
            SubjectChoice(user_id=uid, subject=n, subgroup=g)
            for n, g in body.choices.items()
        )
        db.commit()
        return profile(db, uid)
