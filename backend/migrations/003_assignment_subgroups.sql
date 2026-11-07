CREATE TABLE IF NOT EXISTS assignment_subgroups (
    assignment_id VARCHAR(100) REFERENCES assignments(id) ON DELETE CASCADE,
    subgroup INTEGER NOT NULL,
    PRIMARY KEY (assignment_id, subgroup)
);
