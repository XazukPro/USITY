"""aiogram long-polling bot for a single connected topic per study group."""

import asyncio
import logging
import os
from contextlib import suppress

from aiogram import Bot, Dispatcher, Router
from aiogram.filters import Command

from app.agents.providers import GigaChatProvider
from app.db import make_engine
from app.telegram import (
    ConnectionDenied,
    connect_topic,
    disconnect_topic,
    process_ready_messages,
    queue_text_message,
    topic_status,
)

LOG = logging.getLogger(__name__)


def _topic(message):
    if message.chat.type != "supergroup" or message.message_thread_id is None:
        return None
    return str(message.chat.id), str(message.message_thread_id)


def create_router(engine):
    router = Router()

    @router.message(Command("connect"))
    async def connect(message):
        source = _topic(message)
        if source is None or message.from_user is None:
            return
        parts = (message.text or "").split(maxsplit=1)
        if len(parts) != 2:
            await message.answer("Укажите одноразовый код: /connect CODE")
            return
        try:
            await asyncio.to_thread(
                connect_topic,
                engine,
                parts[1].strip(),
                *source,
                str(message.from_user.id),
            )
        except ConnectionDenied as exc:
            await message.answer(str(exc))
            return
        try:
            await message.delete()
        except Exception:  # Deletion depends on the bot's Telegram permissions.
            LOG.info("Could not delete the one-time connect command")
        await message.answer("Тема подключена. Предложения ДЗ появятся у админа.")

    @router.message(Command("disconnect"))
    async def disconnect(message):
        source = _topic(message)
        if source is None or message.from_user is None:
            return
        try:
            removed = await asyncio.to_thread(
                disconnect_topic, engine, *source, str(message.from_user.id)
            )
        except ConnectionDenied as exc:
            await message.answer(str(exc))
            return
        await message.answer("Тема отключена." if removed else "Тема не подключена.")

    @router.message(Command("status"))
    async def status(message):
        source = _topic(message)
        if source is None:
            return
        connected = await asyncio.to_thread(topic_status, engine, *source)
        await message.answer("Тема подключена." if connected else "Тема не подключена.")

    @router.message()
    async def incoming(message):
        source = _topic(message)
        if source is None or not message.text:
            return
        await asyncio.to_thread(
            queue_text_message,
            engine,
            *source,
            message.message_id,
            message.text,
            message.date,
        )

    return router


async def _process_loop(engine, provider, model_version):
    while True:
        try:
            await asyncio.to_thread(
                process_ready_messages, engine, provider, model_version
            )
        except Exception:
            LOG.exception("Telegram inbox processing failed; will retry")
        await asyncio.sleep(5)


async def run():
    required = (
        "USITY_DATABASE_URL",
        "USITY_TELEGRAM_BOT_TOKEN",
        "GIGACHAT_CREDENTIALS",
    )
    missing = [name for name in required if not os.environ.get(name)]
    if missing:
        raise RuntimeError("Set environment variables: " + ", ".join(missing))
    engine = make_engine(os.environ["USITY_DATABASE_URL"])
    provider = GigaChatProvider(
        os.environ["GIGACHAT_CREDENTIALS"],
        model=os.getenv("GIGACHAT_MODEL", "GigaChat-2"),
        ca_bundle_file=os.getenv("GIGACHAT_CA_BUNDLE_FILE"),
    )
    dispatcher = Dispatcher()
    dispatcher.include_router(create_router(engine))
    worker = asyncio.create_task(
        _process_loop(engine, provider, provider.model)
    )
    try:
        async with Bot(os.environ["USITY_TELEGRAM_BOT_TOKEN"]) as bot:
            await dispatcher.start_polling(bot, handle_as_tasks=False)
    finally:
        worker.cancel()
        with suppress(asyncio.CancelledError):
            await worker
        engine.dispose()


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    asyncio.run(run())
