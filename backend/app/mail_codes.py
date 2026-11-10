import hashlib
import hmac
import os
import secrets
import smtplib
import ssl
from collections.abc import Callable
from dataclasses import dataclass
from datetime import timedelta
from email.message import EmailMessage

from fastapi import HTTPException
from sqlalchemy import delete, select

from app.models import Account, AccountSession, EmailCode, RateBucket, utc_now


@dataclass(frozen=True)
class LoginMail:
    key: bytes
    deliver: Callable[[str, str], None]

    @classmethod
    def configured(cls):
        key = os.getenv("USITY_AUTH_SECRET", "").encode()
        host = os.getenv("USITY_SMTP_HOST")
        sender = os.getenv("USITY_SMTP_FROM")
        if len(key) < 32 or not host or not sender:
            return None

        def deliver(address, code):
            message = EmailMessage()
            message["From"], message["To"], message["Subject"] = (
                sender,
                address,
                "Код входа в USITY",
            )
            message.set_content(f"Код входа: {code}. Срок действия — 10 минут.")
            with smtplib.SMTP_SSL(
                host,
                int(os.getenv("USITY_SMTP_PORT", "465")),
                timeout=10,
                context=ssl.create_default_context(),
            ) as smtp:
                if user := os.getenv("USITY_SMTP_USER"):
                    smtp.login(user, os.environ["USITY_SMTP_PASSWORD"])
                smtp.send_message(message)

        return cls(key, deliver)

    def mac(self, value):
        return hmac.new(self.key, value.encode(), hashlib.sha256).hexdigest()


def insert_for(db, model):
    if db.get_bind().dialect.name == "postgresql":
        from sqlalchemy.dialects.postgresql import insert
    else:
        from sqlalchemy.dialects.sqlite import insert
    return insert(model)


def limit(db, key, seconds, maximum, now):
    db.execute(delete(RateBucket).where(RateBucket.until <= now))
    stmt = insert_for(db, RateBucket).values(
        key=key, until=now + timedelta(seconds=seconds), count=1
    )
    count = db.scalar(
        stmt.on_conflict_do_update(
            index_elements=["key"],
            set_={"count": RateBucket.count + 1},
            where=RateBucket.count < maximum,
        ).returning(RateBucket.count)
    )
    if count is None:
        raise HTTPException(429, "Слишком много попыток. Попробуйте позже.")


def send_code(db, mail, email, ip):
    now = utc_now()
    limit(db, mail.mac("send:" + ip), 600, 20, now)
    limit(db, mail.mac("resend:" + email), 60, 1, now)
    code = f"{secrets.randbelow(1000000):06d}"
    digest = mail.mac(f"otp:{email}:{code}")
    values = {
        "digest": digest,
        "attempts": 0,
        "expires_at": now + timedelta(minutes=10),
    }
    db.execute(delete(EmailCode).where(EmailCode.expires_at <= now))
    db.execute(
        insert_for(db, EmailCode)
        .values(email=email, **values)
        .on_conflict_do_update(index_elements=["email"], set_=values)
    )
    db.commit()
    try:
        mail.deliver(email, code)
    except Exception:
        db.execute(
            delete(EmailCode).where(
                EmailCode.email == email, EmailCode.digest == digest
            )
        )
        db.commit()
        raise HTTPException(
            503, "Не удалось отправить письмо. Попробуйте позже."
        ) from None


def verify_code(db, mail, email, code, ip):
    now = utc_now()
    limit(db, mail.mac("verify:" + ip), 600, 60, now)
    row = db.scalar(select(EmailCode).where(EmailCode.email == email).with_for_update())
    if (
        row is None
        or row.expires_at <= now
        or row.attempts >= 5
        or not hmac.compare_digest(row.digest, mail.mac(f"otp:{email}:{code}"))
    ):
        if row is not None and row.attempts < 5:
            row.attempts += 1
        db.commit()
        raise HTTPException(401, "Код недействителен или истёк")
    db.delete(row)
    user = db.scalar(select(Account).where(Account.email == email))
    if user is None:
        user = Account(email=email)
        db.add(user)
        db.flush()
    token = secrets.token_urlsafe(32)
    db.execute(delete(AccountSession).where(AccountSession.expires_at <= now))
    db.add(
        AccountSession(
            token_hash=hashlib.sha256(token.encode()).hexdigest(),
            user_id=user.id,
            expires_at=now + timedelta(days=30),
        )
    )
    db.commit()
    return token
