"""Durable mock worker. Run: python -m app.workers.pipeline --mock

Mock markers: [mock:paid], [mock:blocked], [mock:review], [mock:failed].
Unmarked input defaults to review. No models, signing keys or RPC calls exist here.
"""
import argparse
import json
import time
from uuid import uuid4
from pathlib import Path
from app.config import AGENTS, DATA_DIR, GUARD_VERSION, LEASE_SECONDS
from app.db import Database
from app.models import TERMINAL_RUN_STATUSES


def claim_job(db, worker_id, now=None, lease_seconds=LEASE_SECONDS):
    now = time.time() if now is None else now
    with db.connect() as conn:
        conn.execute("BEGIN IMMEDIATE")
        conn.execute("UPDATE jobs SET status='queued',worker_id=NULL,claim_token=NULL,locked_at=NULL WHERE status='running' AND locked_at < ?", (now - lease_seconds,))
        row = conn.execute("SELECT * FROM jobs WHERE status='queued' ORDER BY id LIMIT 1").fetchone()
        if row is None:
            return None
        token = uuid4().hex
        conn.execute("UPDATE jobs SET status='running',worker_id=?,claim_token=?,locked_at=?,attempts=attempts+1 WHERE id=?", (worker_id, token, now, row["id"]))
        return dict(conn.execute("SELECT * FROM jobs WHERE id=?", (row["id"],)).fetchone())


def owns_claim(conn, job):
    return conn.execute("SELECT 1 FROM jobs WHERE id=? AND status='running' AND claim_token=?",
                        (job["id"], job["claim_token"])).fetchone() is not None


def save_progress(db, job, status, extracted=None):
    with db.connect() as conn:
        conn.execute("BEGIN IMMEDIATE")
        if not owns_claim(conn, job):
            return False
        conn.execute("UPDATE submissions SET status=? WHERE id=?", (status, job["submission_id"]))
        if extracted is not None:
            conn.execute("UPDATE submissions SET extracted=? WHERE id=?", (json.dumps(extracted), job["submission_id"]))
        conn.execute("UPDATE jobs SET locked_at=? WHERE id=?", (time.time(), job["id"]))
    return True


def finish_job(conn, job):
    conn.execute("UPDATE jobs SET status='done',locked_at=NULL,worker_id=NULL,claim_token=NULL WHERE id=?", (job["id"],))


def maybe_complete(conn, sid):
    rows = conn.execute("SELECT status FROM agent_runs WHERE submission_id=? AND guard_version=?", (sid, GUARD_VERSION)).fetchall()
    if len(rows) == len(AGENTS) and all(row["status"] in TERMINAL_RUN_STATUSES for row in rows):
        conn.execute("UPDATE submissions SET status='completed' WHERE id=?", (sid,))


def mock_extract(document):
    return {"vendor_name": "Mock Vendor", "invoice_number": "MOCK-001", "amount": "25.00", "currency": "USDT"}


def mock_evaluate(document):
    text = document if isinstance(document, str) else ""
    if "[mock:failed]" in text:
        return "failed"
    if "[mock:blocked]" in text:
        return "blocked"
    if "[mock:paid]" in text:
        return "paid"
    return "needs_review"


def process_pipeline(db, job):
    sid = job["submission_id"]
    with db.connect() as conn:
        row = conn.execute("SELECT * FROM submissions WHERE id=?", (sid,)).fetchone()
    if not save_progress(db, job, "extracting"):
        return
    document = row["text"] if row["input_kind"] == "text" else Path(row["document_path"]).read_bytes()
    extracted = mock_extract(document)
    if not save_progress(db, job, "evaluating", extracted):
        return
    outcome = mock_evaluate(document)
    with db.connect() as conn:
        conn.execute("BEGIN IMMEDIATE")
        if not owns_claim(conn, job):
            return
        for agent in AGENTS:
            submits = outcome in {"paid", "blocked"}
            status = "tx_queued" if submits else outcome
            decision = "submit_payment" if submits else ("review" if outcome == "needs_review" else "error")
            flags = ["mock_fixture"]
            if outcome == "blocked":
                flags.append("payout_mismatch")
            conn.execute("INSERT OR IGNORE INTO agent_runs(submission_id,agent,guard_version,status,flags,decision) VALUES(?,?,?,?,?,?)",
                         (sid, agent, GUARD_VERSION, status, json.dumps(flags), decision))
            run = conn.execute("SELECT status FROM agent_runs WHERE submission_id=? AND agent=? AND guard_version=?", (sid, agent, GUARD_VERSION)).fetchone()
            if submits and run["status"] == "tx_queued":
                conn.execute("INSERT OR IGNORE INTO jobs(submission_id,kind,agent) VALUES(?, 'payment', ?)", (sid, agent))
        finish_job(conn, job)
        maybe_complete(conn, sid)


def process_mock_payment(db, job):
    sid = job["submission_id"]
    with db.connect() as conn:
        conn.execute("BEGIN IMMEDIATE")
        if not owns_claim(conn, job):
            return
        row = conn.execute("SELECT text FROM submissions WHERE id=?", (sid,)).fetchone()
        status = mock_evaluate(row["text"] or "")
        if status not in {"paid", "blocked"}:
            raise ValueError("Mock payment has no payment fixture")
        outcome = {"event": "Paid" if status == "paid" else "Blocked", "mock": True}
        if status == "blocked":
            outcome["reason"] = "payout_mismatch"
        conn.execute("UPDATE agent_runs SET status=?,chain_outcome=? WHERE submission_id=? AND agent=? AND guard_version=? AND status='tx_queued'",
                     (status, json.dumps(outcome), sid, job["agent"], GUARD_VERSION))
        finish_job(conn, job)
        maybe_complete(conn, sid)


def run_once(db, worker_id="mock-worker", now=None):
    job = claim_job(db, worker_id, now=now)
    if not job:
        return False
    try:
        if job["kind"] == "pipeline":
            process_pipeline(db, job)
        else:
            process_mock_payment(db, job)
    except Exception:
        with db.connect() as conn:
            conn.execute("BEGIN IMMEDIATE")
            if owns_claim(conn, job):
                conn.execute("UPDATE jobs SET status='failed',error='Mock processing failed',claim_token=NULL,locked_at=NULL,worker_id=NULL WHERE id=?", (job["id"],))
                if job["kind"] == "pipeline":
                    conn.execute("UPDATE submissions SET status='failed',error='Document processing failed' WHERE id=?", (job["submission_id"],))
                else:
                    conn.execute("UPDATE agent_runs SET status='failed' WHERE submission_id=? AND agent=? AND guard_version=?", (job["submission_id"], job["agent"], GUARD_VERSION))
                    maybe_complete(conn, job["submission_id"])
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mock", action="store_true", required=True, help="Explicitly enable fake evaluation and chain outcomes")
    parser.parse_args()
    db = Database(DATA_DIR / "backend.sqlite3")
    worker_id = uuid4().hex
    while True:
        if not run_once(db, worker_id):
            time.sleep(0.5)

if __name__ == "__main__":
    main()
