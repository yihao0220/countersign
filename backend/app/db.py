from contextlib import contextmanager
from pathlib import Path
import sqlite3

SCHEMA = """
CREATE TABLE IF NOT EXISTS submissions (
 id TEXT PRIMARY KEY, created_at TEXT NOT NULL, nickname TEXT NOT NULL,
 input_kind TEXT NOT NULL, document_path TEXT, text TEXT,
 status TEXT NOT NULL DEFAULT 'queued', extracted TEXT, error TEXT
);
CREATE TABLE IF NOT EXISTS jobs (
 id INTEGER PRIMARY KEY, submission_id TEXT NOT NULL REFERENCES submissions(id),
 kind TEXT NOT NULL, agent TEXT NOT NULL DEFAULT '',
 status TEXT NOT NULL DEFAULT 'queued', attempts INTEGER NOT NULL DEFAULT 0,
 locked_at REAL, worker_id TEXT, claim_token TEXT, error TEXT,
 UNIQUE(submission_id, kind, agent)
);
CREATE TABLE IF NOT EXISTS agent_runs (
 submission_id TEXT NOT NULL REFERENCES submissions(id), agent TEXT NOT NULL,
 guard_version TEXT NOT NULL, status TEXT NOT NULL, flags TEXT NOT NULL,
 decision TEXT NOT NULL, tx_hash TEXT, chain_outcome TEXT,
 PRIMARY KEY(submission_id, agent, guard_version)
);
CREATE INDEX IF NOT EXISTS inbox_order ON submissions(created_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS job_queue ON jobs(kind, status, id);
"""

class Database:
    def __init__(self, path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.connect() as conn:
            conn.executescript(SCHEMA)

    @contextmanager
    def connect(self):
        conn = sqlite3.connect(self.path, timeout=10)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA foreign_keys=ON")
        try:
            yield conn
            conn.commit()
        except BaseException:
            conn.rollback()
            raise
        finally:
            conn.close()
