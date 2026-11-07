CREATE TABLE IF NOT EXISTS study_groups (
	id VARCHAR(100) NOT NULL,
	PRIMARY KEY (id)
);
CREATE TABLE IF NOT EXISTS lessons (
	id VARCHAR(100) NOT NULL,
	group_id VARCHAR(100) NOT NULL,
	subject VARCHAR(200) NOT NULL,
	starts_at TIMESTAMP WITH TIME ZONE NOT NULL,
	ends_at TIMESTAMP WITH TIME ZONE NOT NULL,
	teacher VARCHAR(200) NOT NULL,
	location VARCHAR(500) NOT NULL,
	PRIMARY KEY (id),
	CHECK (ends_at > starts_at),
	FOREIGN KEY(group_id) REFERENCES study_groups (id)
);
CREATE INDEX IF NOT EXISTS ix_lessons_group_id ON lessons (group_id);
CREATE TABLE IF NOT EXISTS memberships (
	user_id VARCHAR(100) NOT NULL,
	group_id VARCHAR(100) NOT NULL,
	role VARCHAR(20) NOT NULL,
	PRIMARY KEY (user_id),
	CHECK (role IN ('owner','admin','student')),
	FOREIGN KEY(group_id) REFERENCES study_groups (id)
);
CREATE INDEX IF NOT EXISTS ix_memberships_group_id ON memberships (group_id);
CREATE TABLE IF NOT EXISTS review_drafts (
	id VARCHAR(100) NOT NULL,
	group_id VARCHAR(100) NOT NULL,
	event_id VARCHAR(200) NOT NULL,
	text TEXT NOT NULL,
	source_context JSON NOT NULL,
	model_output JSON NOT NULL,
	raw_output TEXT,
	model_version VARCHAR(200) NOT NULL,
	prompt_version VARCHAR(100) NOT NULL,
	status VARCHAR(20) NOT NULL,
	version INTEGER NOT NULL,
	created_at TIMESTAMP WITH TIME ZONE NOT NULL,
	human_output JSON,
	decided_by VARCHAR(100),
	decided_at TIMESTAMP WITH TIME ZONE,
	PRIMARY KEY (id),
	UNIQUE (group_id, event_id),
	CHECK (status IN ('pending','approved','rejected')),
	CHECK (version >= 1),
	FOREIGN KEY(group_id) REFERENCES study_groups (id)
);
CREATE INDEX IF NOT EXISTS ix_review_drafts_group_id ON review_drafts (group_id);
CREATE TABLE IF NOT EXISTS telegram_connect_codes (
	group_id VARCHAR(100) NOT NULL,
	code_hash VARCHAR(64) NOT NULL,
	expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
	PRIMARY KEY (group_id),
	FOREIGN KEY(group_id) REFERENCES study_groups (id),
	UNIQUE (code_hash)
);
CREATE TABLE IF NOT EXISTS telegram_inbox (
	chat_id VARCHAR(100) NOT NULL,
	topic_id VARCHAR(100) NOT NULL,
	message_id INTEGER NOT NULL,
	group_id VARCHAR(100) NOT NULL,
	text TEXT NOT NULL,
	sent_at TIMESTAMP WITH TIME ZONE NOT NULL,
	received_at TIMESTAMP WITH TIME ZONE NOT NULL,
	event_id VARCHAR(200),
	processed_at TIMESTAMP WITH TIME ZONE,
	PRIMARY KEY (chat_id, topic_id, message_id),
	FOREIGN KEY(group_id) REFERENCES study_groups (id)
);
CREATE INDEX IF NOT EXISTS ix_telegram_inbox_group_id ON telegram_inbox (group_id);
CREATE TABLE IF NOT EXISTS telegram_integrations (
	group_id VARCHAR(100) NOT NULL,
	chat_id VARCHAR(100) NOT NULL,
	topic_id VARCHAR(100) NOT NULL,
	owner_telegram_id VARCHAR(100),
	PRIMARY KEY (group_id),
	UNIQUE (chat_id, topic_id),
	FOREIGN KEY(group_id) REFERENCES study_groups (id)
);
CREATE TABLE IF NOT EXISTS assignments (
	id VARCHAR(100) NOT NULL,
	group_id VARCHAR(100) NOT NULL,
	lesson_id VARCHAR(100) NOT NULL,
	draft_id VARCHAR(100) NOT NULL,
	text TEXT NOT NULL,
	version INTEGER NOT NULL,
	PRIMARY KEY (id),
	CHECK (version >= 1),
	FOREIGN KEY(group_id) REFERENCES study_groups (id),
	FOREIGN KEY(lesson_id) REFERENCES lessons (id),
	UNIQUE (draft_id),
	FOREIGN KEY(draft_id) REFERENCES review_drafts (id)
);
CREATE INDEX IF NOT EXISTS ix_assignments_group_id ON assignments (group_id);
CREATE TABLE IF NOT EXISTS ingested_events (
	group_id VARCHAR(100) NOT NULL,
	event_id VARCHAR(200) NOT NULL,
	payload_hash VARCHAR(64) NOT NULL,
	draft_id VARCHAR(100),
	PRIMARY KEY (group_id, event_id),
	FOREIGN KEY(group_id) REFERENCES study_groups (id),
	FOREIGN KEY(draft_id) REFERENCES review_drafts (id)
);
CREATE TABLE IF NOT EXISTS session_tokens (
	token_hash VARCHAR(64) NOT NULL,
	user_id VARCHAR(100) NOT NULL,
	expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
	PRIMARY KEY (token_hash),
	FOREIGN KEY(user_id) REFERENCES memberships (user_id)
);
CREATE TABLE IF NOT EXISTS assignment_completions (
	assignment_id VARCHAR(100) NOT NULL,
	user_id VARCHAR(100) NOT NULL,
	version INTEGER NOT NULL,
	completed BOOLEAN NOT NULL,
	updated_at TIMESTAMP WITH TIME ZONE NOT NULL,
	PRIMARY KEY (assignment_id, user_id),
	FOREIGN KEY(assignment_id) REFERENCES assignments (id),
	FOREIGN KEY(user_id) REFERENCES memberships (user_id)
);
