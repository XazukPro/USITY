"""Loopback-only account demo. Use a private state directory outside the repo."""

import argparse
import os
import secrets
from pathlib import Path

import uvicorn

from app.api import create_app
from app.mail_codes import LoginMail
from migrate import migrate


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("state", type=Path)
    parser.add_argument("--port", type=int, default=8074)
    args = parser.parse_args()
    path = args.state.resolve()
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.stat().st_mode & 0o077:
        raise SystemExit("Требуется отдельная папка с правами 0700")
    key_path = path / "auth.key"
    if not key_path.exists():
        with key_path.open("xb") as f:
            f.write(secrets.token_bytes(32))

    def deliver(address, code):
        if not address.endswith("@example.test"):
            raise ValueError("Synthetic domain only")
        # Atomic replacement so concurrent readers never see a partial code.
        temp = path / secrets.token_hex(16)
        with temp.open("x", encoding="utf-8") as f:
            f.write(f"Получатель: {address}\nКод USITY: {code}\n")
        temp.replace(path / (address + ".txt"))

    url = f"sqlite:///{path / 'stand.sqlite'}"
    migrate(url)
    uvicorn.run(
        create_app(url, login_mail=LoginMail(key_path.read_bytes(), deliver)),
        host="127.0.0.1",
        port=args.port,
        access_log=False,
    )


if __name__ == "__main__":
    os.umask(0o077)
    main()
