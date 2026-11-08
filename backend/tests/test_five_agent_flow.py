
from sqlalchemy.orm import Session

from app.agents.contracts import AgentRun, EventBundle, SourceMessage
from app.agents.registry import AGENT_IDS
from app.ingestion import ingest_event_bundle
from app.models import Draft, TelegramIntegration


class FixedAgent:
    def __init__(self, agent_id, fail=False):
        self.agent_id = agent_id
        self.fail = fail

    def run(self, bundle):
        if self.fail:
            raise RuntimeError("provider unavailable")
        return AgentRun.not_found(self.agent_id, "fake-v1", "prompt-v1")


def test_five_agent_bundle_creates_one_pending_review_draft(setup):
    s = setup
    with s["engine"].begin() as db:
        db.execute(
            TelegramIntegration.__table__.insert(),
            {"group_id": s["group"], "chat_id": "-100123", "topic_id": "42"},
        )
    bundle = EventBundle(
        group_id=s["group"],
        chat_id="-100123",
        topic_id="42",
        connected_chat_id="-100123",
        connected_topic_id="42",
        messages=(
            SourceMessage(
                id=101,
                chat_id="-100123",
                topic_id="42",
                text="ДЗ: решить 4 и 5",
                sent_at="2026-11-08T10:00:00+03:00",
            ),
        ),
    )

    draft_id = ingest_event_bundle(
        s["engine"], "five-agent-event", bundle, [FixedAgent(agent_id) for agent_id in AGENT_IDS]
    )

    with Session(s["engine"]) as db:
        draft = db.get(Draft, draft_id)
        assert draft.status == "pending"
        assert [item["agent_id"] for item in draft.proposal_set["runs"]] == list(AGENT_IDS)
        assert all(item["status"] == "not_found" for item in draft.proposal_set["runs"])


def test_one_agent_failure_is_visible_without_losing_other_runs(setup):
    s = setup
    with s["engine"].begin() as db:
        db.execute(
            TelegramIntegration.__table__.insert(),
            {"group_id": s["group"], "chat_id": "-100123", "topic_id": "42"},
        )
    bundle = EventBundle(
        group_id=s["group"],
        chat_id="-100123",
        topic_id="42",
        connected_chat_id="-100123",
        connected_topic_id="42",
        messages=(
            SourceMessage(1, "-100123", "42", "Текст", "2026-11-08T10:00:00+03:00"),
        ),
    )
    agents = [FixedAgent(agent_id, agent_id == "material_proposal") for agent_id in AGENT_IDS]

    draft_id = ingest_event_bundle(s["engine"], "failure-event", bundle, agents)

    review = s["client"].get(
        f"/groups/{s['group']}/review",
        headers={"Authorization": "Bearer " + s["users"]["admin"]},
    ).json()
    draft = next(item for item in review if item["id"] == draft_id)
    runs = {item["agent_id"]: item for item in draft["proposal_set"]["runs"]}
    assert runs["material_proposal"]["status"] == "error"
    assert runs["assignment_change"]["status"] == "not_found"

