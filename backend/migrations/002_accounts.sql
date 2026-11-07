CREATE TABLE IF NOT EXISTS accounts (
	id VARCHAR(100) NOT NULL,
	email VARCHAR(254) NOT NULL,
	PRIMARY KEY (id),
	UNIQUE (email)
);
CREATE TABLE IF NOT EXISTS email_codes (
	email VARCHAR(254) NOT NULL,
	digest VARCHAR(64) NOT NULL,
	expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
	attempts INTEGER NOT NULL,
	PRIMARY KEY (email)
);
CREATE TABLE IF NOT EXISTS login_limits (
	key VARCHAR(64) NOT NULL,
	until TIMESTAMP WITH TIME ZONE NOT NULL,
	count INTEGER NOT NULL,
	PRIMARY KEY (key)
);
CREATE INDEX IF NOT EXISTS ix_login_limits_until ON login_limits (until);
CREATE TABLE IF NOT EXISTS account_sessions (
	token_hash VARCHAR(64) NOT NULL,
	user_id VARCHAR(100) NOT NULL,
	expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
	PRIMARY KEY (token_hash),
	FOREIGN KEY(user_id) REFERENCES accounts (id)
);
CREATE INDEX IF NOT EXISTS ix_account_sessions_user_id ON account_sessions (user_id);
CREATE TABLE IF NOT EXISTS group_details (
	group_id VARCHAR(100) NOT NULL,
	name VARCHAR(100) NOT NULL,
	semester JSON NOT NULL,
	invite_nonce VARCHAR(64) NOT NULL,
	PRIMARY KEY (group_id),
	FOREIGN KEY(group_id) REFERENCES study_groups (id)
);
CREATE TABLE IF NOT EXISTS lesson_details (
	lesson_id VARCHAR(100) NOT NULL,
	kind VARCHAR(20) NOT NULL,
	subgroup INTEGER,
	PRIMARY KEY (lesson_id),
	FOREIGN KEY(lesson_id) REFERENCES lessons (id)
);
CREATE TABLE IF NOT EXISTS subject_choices (
	user_id VARCHAR(100) NOT NULL,
	subject VARCHAR(200) NOT NULL,
	subgroup INTEGER NOT NULL,
	PRIMARY KEY (user_id, subject),
	FOREIGN KEY(user_id) REFERENCES memberships (user_id)
);
