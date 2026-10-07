"""Database records are defined by the SQLite schema in db.py.

Milestone one uses sqlite3 directly so job claiming and idempotency constraints
are explicit. A later SQLModel migration can preserve this schema.
"""
TERMINAL_RUN_STATUSES = frozenset({"paid", "blocked", "needs_review", "failed"})
