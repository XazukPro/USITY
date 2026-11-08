# Unified Five AI Agents Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (\`- [ ]\`) syntax for tracking.

**Goal:** Deliver five explicit, independently callable AI agents and a FastAPI worker path that saves their combined suggestions as one admin-review draft without automatic publication.

**Architecture:** A typed common \`EventBundle\` and \`AgentProposal\` replace isolated prototype shapes. A registry invokes the five agents independently with per-agent model adapters, and the orchestration layer persists raw responses, versions and structured suggestions in one review draft. The existing human-only decision route remains the publication boundary; review responses expose all five slots.

**Tech Stack:** Python 3.14, FastAPI, SQLAlchemy, Pydantic, standard-library HTTPS adapters, pytest/unittest.

**Spec:** \`docs/superpowers/specs/2026-11-08-unified-five-ai-agents-design.md\`; \`docs/product/mvp.md\`; \`docs/research/ai-course-notes-ru.md\`.

## Global Constraints

- Process only the configured Telegram chat and topic; messages and OCR are untrusted data, not instructions.
- Each model only produces a draft; only an admin action may publish, change or cancel group data.
- Persist source context, raw model output, model/prompt versions and human decision separately.
- Do not add secrets, real chats or personally identifying data to Git.
- Every agent has a separate entry point, strict result validation and synthetic independent tests.
- Keep provider integration replaceable; do not introduce a production key, OCR provider, Redis worker or Telegram bot.

## Review Focus

- A message from the same chat but another topic must be rejected before any model is called (Task 1).
- A malformed result from one agent must remain a visible error while the other four results survive (Task 7).
- A hallucinated message or assignment ID must never become a proposal field (Tasks 2–6).
- Prompt-injection text remains data and cannot cause publication (Tasks 2 and 7).
- Material, duplicate and change suggestions cannot mutate data before an admin decision (Task 7).

## File Structure

- \`backend/app/agents/contracts.py\` — common input/output contracts and response validation.
- \`backend/app/agents/providers.py\` — replaceable provider protocol and HTTPS adapter.
- \`backend/app/agents/{homework,schedule_binding,duplicates,materials,assignment_changes}.py\` — the five named agents.
- \`backend/app/agents/registry.py\` — independent invocation and per-agent error reporting.
- \`backend/app/{ingestion,models,api,schemas}.py\` — trusted persistence and review display.
- \`backend/tests/test_*agent.py\`, \`backend/tests/test_five_agent_flow.py\` — synthetic agent and flow tests.

---

### Task 1: Common Contracts and Five-Agent Registry

**Files:**
- Create: \`backend/app/agents/contracts.py\`
- Create: \`backend/app/agents/registry.py\`
- Create: \`backend/tests/test_agent_registry.py\`

**Interfaces:** Produces \`EventBundle\`, \`SourceMessage\`, \`Attachment\`, \`AgentProposal\`, \`AgentRun\` and \`run_all_agents(bundle, agents)\`. Later tasks implement \`Agent.run(bundle, provider) -> AgentRun\`.

- [ ] **Step 1: Write failing registry tests**

Test that a connected-topic bundle produces exactly \`homework_detection\`, \`schedule_binding\`, \`duplicate_conflict\`, \`material_proposal\`, \`assignment_change\`; test that an off-topic message raises before an agent call.

- [ ] **Step 2: Run the red test**

Run: \`PYTHONPATH=backend .venv/bin/python -m pytest backend/tests/test_agent_registry.py -v\`

Expected: FAIL because contracts and registry do not exist.

- [ ] **Step 3: Implement common contracts and registry**

Use frozen dataclasses, validate source membership and execute every registered agent independently. Convert an agent-local exception into an error run.

- [ ] **Step 4: Run the green test**

Run: \`PYTHONPATH=backend .venv/bin/python -m pytest backend/tests/test_agent_registry.py -v\`

Expected: PASS.

- [ ] **Step 5: Commit**

\`\`\`bash
git add backend/app/agents/contracts.py backend/app/agents/registry.py backend/tests/test_agent_registry.py
git commit -m "feat: add common five-agent contracts"
\`\`\`

### Task 2: New Homework Agent

**Files:**
- Modify: \`backend/app/agents/homework.py\`
- Modify: \`backend/tests/test_homework_agent.py\`

**Interfaces:** Consumes Task 1 contracts. Produces an \`AgentRun\` with \`agent_id="homework_detection"\` and zero or one proposal.

- [ ] **Step 1: Write a failing common-contract test**

A two-message assignment produces a proposal with versions; unknown source IDs are rejected.

- [ ] **Step 2: Run the red test**

Run: \`PYTHONPATH=backend .venv/bin/python -m pytest backend/tests/test_homework_agent.py -v\`

Expected: FAIL because the common run wrapper is absent.

- [ ] **Step 3: Implement \`run_homework_detection(bundle, provider)\`**

Keep \`detect_homework\` compatible for existing ingestion callers; map it to the common result and retain raw output/version metadata.

- [ ] **Step 4: Run the green test**

Run: \`PYTHONPATH=backend .venv/bin/python -m pytest backend/tests/test_homework_agent.py -v\`

Expected: PASS.

- [ ] **Step 5: Commit**

\`\`\`bash
git add backend/app/agents/homework.py backend/tests/test_homework_agent.py
git commit -m "feat: adapt homework detector to shared contract"
\`\`\`

### Task 3: Schedule-Binding Agent

**Files:**
- Create: \`backend/app/agents/schedule_binding.py\`
- Create: \`backend/tests/test_schedule_binding_agent.py\`

**Interfaces:** Consumes \`EventBundle.subjects\`, \`EventBundle.lessons\` and source messages. Produces \`AgentRun(agent_id="schedule_binding")\`.

- [ ] **Step 1: Write failing tests**

Cover an alias plus “к следующей паре”, ambiguous subject, past date, changed/cancelled slot and unknown source ID.

- [ ] **Step 2: Run the red test**

Run: \`PYTHONPATH=backend .venv/bin/python -m pytest backend/tests/test_schedule_binding_agent.py -v\`

Expected: FAIL because the module does not exist.

- [ ] **Step 3: Implement \`run_schedule_binding(bundle, provider, now)\`**

Port the existing deterministic date/parity/override rules through the common contract. Ambiguous or past results receive review flags and never guess a lesson.

- [ ] **Step 4: Run the green test**

Run: \`PYTHONPATH=backend .venv/bin/python -m pytest backend/tests/test_schedule_binding_agent.py -v\`

Expected: PASS.

- [ ] **Step 5: Commit**

\`\`\`bash
git add backend/app/agents/schedule_binding.py backend/tests/test_schedule_binding_agent.py
git commit -m "feat: add shared schedule-binding agent"
\`\`\`

### Task 4: Duplicate and Conflict Agent

**Files:**
- Create: \`backend/app/agents/duplicates.py\`
- Create: \`backend/tests/test_duplicate_agent.py\`

**Interfaces:** Consumes messages and \`EventBundle.active_assignments\`. Produces \`AgentRun(agent_id="duplicate_conflict")\`.

- [ ] **Step 1: Write failing tests**

Cover a similar active task, no duplicate, unknown assignment ID and an uncited source.

- [ ] **Step 2: Run the red test**

Run: \`PYTHONPATH=backend .venv/bin/python -m pytest backend/tests/test_duplicate_agent.py -v\`

Expected: FAIL because the module does not exist.

- [ ] **Step 3: Implement \`run_duplicate_conflict(bundle, provider)\`**

Validate structured JSON against active assignments and cited messages; return candidates/explanation only and never merge or delete.

- [ ] **Step 4: Run the green test**

Run: \`PYTHONPATH=backend .venv/bin/python -m pytest backend/tests/test_duplicate_agent.py -v\`

Expected: PASS.

- [ ] **Step 5: Commit**

\`\`\`bash
git add backend/app/agents/duplicates.py backend/tests/test_duplicate_agent.py
git commit -m "feat: add duplicate conflict agent"
\`\`\`

### Task 5: Material-Proposal Agent

**Files:**
- Create: \`backend/app/agents/materials.py\`
- Create: \`backend/tests/test_material_agent.py\`

**Interfaces:** Consumes trusted attachment metadata, precomputed OCR, subjects, categories and active assignments. Produces \`AgentRun(agent_id="material_proposal")\`.

- [ ] **Step 1: Write failing tests**

Cover photo OCR, a supported PDF, a cited link, unsupported/oversized file and unknown category/subject.

- [ ] **Step 2: Run the red test**

Run: \`PYTHONPATH=backend .venv/bin/python -m pytest backend/tests/test_material_agent.py -v\`

Expected: FAIL because the module does not exist.

- [ ] **Step 3: Implement \`run_material_proposal(bundle, provider)\`**

Validate attachments and links, use only OCR passed by trusted ingestion, and require uncertainty for unknown classification fields. Never inspect documents or call an OCR service.

- [ ] **Step 4: Run the green test**

Run: \`PYTHONPATH=backend .venv/bin/python -m pytest backend/tests/test_material_agent.py -v\`

Expected: PASS.

- [ ] **Step 5: Commit**

\`\`\`bash
git add backend/app/agents/materials.py backend/tests/test_material_agent.py
git commit -m "feat: add material proposal agent"
\`\`\`

### Task 6: Assignment-Change Agent

**Files:**
- Create: \`backend/app/agents/assignment_changes.py\`
- Create: \`backend/tests/test_assignment_change_agent.py\`

**Interfaces:** Consumes messages, OCR and active assignments. Produces \`AgentRun(agent_id="assignment_change")\`.

- [ ] **Step 1: Write failing tests**

Cover cancellation, text correction, moved due date, ambiguous target, invalid source ID and provider failure.

- [ ] **Step 2: Run the red test**

Run: \`PYTHONPATH=backend .venv/bin/python -m pytest backend/tests/test_assignment_change_agent.py -v\`

Expected: FAIL because the module does not exist.

- [ ] **Step 3: Implement \`run_assignment_change(bundle, provider, today)\`**

Validate active targets and cited evidence. Mark ambiguity and past dates for review; never mutate an assignment.

- [ ] **Step 4: Run the green test**

Run: \`PYTHONPATH=backend .venv/bin/python -m pytest backend/tests/test_assignment_change_agent.py -v\`

Expected: PASS.

- [ ] **Step 5: Commit**

\`\`\`bash
git add backend/app/agents/assignment_changes.py backend/tests/test_assignment_change_agent.py
git commit -m "feat: add assignment change agent"
\`\`\`

### Task 7: Orchestration, Draft Persistence and Review API

**Files:**
- Modify: \`backend/app/ingestion.py\`
- Modify: \`backend/app/models.py\`
- Modify: \`backend/app/api.py\`
- Modify: \`backend/app/schemas.py\`
- Create: \`backend/tests/test_five_agent_flow.py\`
- Modify: \`backend/tests/test_ingestion.py\`
- Modify: \`backend/tests/test_review_api.py\`

**Interfaces:** Consumes five \`AgentRun\` values and produces one review draft whose API representation lists all five named runs.

- [ ] **Step 1: Write failing flow/API tests**

Use five fixed providers to prove every agent runs on one connected bundle, one failure remains visible without erasing others, and no assignment/material is published before an admin decision.

- [ ] **Step 2: Run the red test**

Run: \`PYTHONPATH=backend .venv/bin/python -m pytest backend/tests/test_five_agent_flow.py backend/tests/test_review_api.py -v\`

Expected: FAIL because combined proposals are neither persisted nor exposed.

- [ ] **Step 3: Implement additive persistence and orchestration**

Add a versioned JSON proposal set to \`Draft\`; preserve legacy homework fields. \`ingest_event_bundle\` checks source membership before/after model calls, invokes the registry and writes one pending draft. The review API returns all named runs; it never auto-publishes, changes or cancels data.

- [ ] **Step 4: Run integration tests**

Run: \`PYTHONPATH=backend .venv/bin/python -m pytest backend/tests/test_five_agent_flow.py backend/tests/test_ingestion.py backend/tests/test_review_api.py -v\`

Expected: PASS.

- [ ] **Step 5: Commit**

\`\`\`bash
git add backend/app/ingestion.py backend/app/models.py backend/app/api.py backend/app/schemas.py backend/tests/test_five_agent_flow.py backend/tests/test_ingestion.py backend/tests/test_review_api.py
git commit -m "feat: orchestrate five AI agents into review drafts"
\`\`\`

### Task 8: Documentation and Full Verification

**Files:**
- Modify: \`backend/README.md\`
- Modify: \`docs/product/mvp.md\`
- Modify: \`backend/tests/test_demo.py\`

**Interfaces:** Documents the five IDs, GigaChat-first configurable adapter and synthetic-only test path.

- [ ] **Step 1: Write a failing demo assertion**

Assert that a deterministic review response exposes all five agent IDs without credentials.

- [ ] **Step 2: Run the red test**

Run: \`PYTHONPATH=backend .venv/bin/python -m pytest backend/tests/test_demo.py -v\`

Expected: FAIL until the demo exposes five-agent visibility.

- [ ] **Step 3: Document unified flow and provider boundary**

State that GigaChat is the default integration direction, while adapters remain replaceable; explain that real Telegram/OCR/Redis are not introduced by this change.

- [ ] **Step 4: Run whole-backend verification**

Run: \`PYTHONPATH=backend .venv/bin/python -m pytest backend/tests -v && .venv/bin/ruff check backend\`

Expected: PASS.

- [ ] **Step 5: Commit**

\`\`\`bash
git add backend/README.md docs/product/mvp.md backend/tests/test_demo.py
git commit -m "docs: describe unified five-agent review flow"
\`\`\`

## Self-Review

- **Spec coverage:** Tasks 1–6 create independently callable agents; Task 7 adds one protected review flow; Task 8 makes five agents and limits visible. Real OCR, Telegram, Redis and quality benchmarking remain out of scope.
- **Step scan:** Every task has RED, an expected failing command, exact interface, GREEN and commit.
- **Type consistency:** All agents return \`AgentRun\`; registry consumes agents; ingestion stores registry output; API returns persisted runs.
- **Review focus:** Each risk has a named owning task and test.
- **Proportion:** This defines interfaces and observable behavior, not code bodies.

