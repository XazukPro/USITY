CREATE TABLE IF NOT EXISTS personal_tasks (
    user_id VARCHAR(100) NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    id VARCHAR(36) NOT NULL,
    title TEXT NOT NULL,
    day DATE NOT NULL,
    start INTEGER,
    duration INTEGER NOT NULL CHECK (duration BETWEEN 1 AND 1440),
    remind BOOLEAN NOT NULL,
    completed_at TIMESTAMP WITH TIME ZONE,
    version INTEGER NOT NULL CHECK (version >= 1),
    PRIMARY KEY (user_id, id),
    CHECK (start IS NULL OR (start >= 0 AND start + duration <= 1440))
);
CREATE INDEX IF NOT EXISTS ix_personal_tasks_user_completed
    ON personal_tasks (user_id, completed_at);
CREATE TABLE IF NOT EXISTS personal_task_receipts (
    user_id VARCHAR(100) NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    mutation_id VARCHAR(36) NOT NULL,
    result_hash VARCHAR(64) NOT NULL,
    PRIMARY KEY (user_id, mutation_id)
);
