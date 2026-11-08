CREATE TABLE IF NOT EXISTS material_categories (
    group_id VARCHAR(100) NOT NULL REFERENCES study_groups(id),
    normalized VARCHAR(200) NOT NULL,
    name VARCHAR(80) NOT NULL,
    PRIMARY KEY (group_id, normalized)
);
CREATE TABLE IF NOT EXISTS library_materials (
    id VARCHAR(32) PRIMARY KEY,
    group_id VARCHAR(100) NOT NULL REFERENCES study_groups(id),
    creator VARCHAR(100) NOT NULL,
    scope VARCHAR(10) NOT NULL CHECK (scope IN ('group','personal')),
    status VARCHAR(12) NOT NULL CHECK (status IN ('pending','published','rejected')),
    title VARCHAR(200) NOT NULL,
    category VARCHAR(80) NOT NULL,
    subjects JSON NOT NULL,
    url TEXT,
    filename VARCHAR(180),
    mime VARCHAR(120),
    size INTEGER,
    blob_key VARCHAR(32) UNIQUE,
    reviewed_by VARCHAR(100),
    created_at TIMESTAMP WITH TIME ZONE NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_library_materials_group_id ON library_materials(group_id);
CREATE TABLE IF NOT EXISTS material_blob_cleanup (
    blob_key VARCHAR(32) PRIMARY KEY,
    due TIMESTAMP WITH TIME ZONE NOT NULL
);
