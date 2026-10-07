import base64
from concurrent.futures import ThreadPoolExecutor
from io import BytesIO
import pytest
from fastapi.testclient import TestClient
from PIL import Image
from pypdf import PdfWriter
from app.main import create_app
from app.db import Database
from app.workers.pipeline import claim_job, run_once, process_pipeline

@pytest.fixture
def setup(tmp_path):
    app = create_app(tmp_path)
    with TestClient(app) as client:
        yield client, app.state.db, tmp_path


def drain(db):
    for _ in range(30):
        if not run_once(db):
            return
    raise AssertionError("Jobs did not drain")


def image_bytes(fmt="PNG"):
    output = BytesIO()
    Image.new("RGB", (10, 10)).save(output, format=fmt)
    return output.getvalue()


def test_file_and_text_share_workflow(setup):
    client, db, root = setup
    a = client.post("/api/invoices", files={"file": ("../../invoice.png", image_bytes(), "image/png")})
    b = client.post("/api/invoices/text", json={"text": "Invoice", "nickname": "Alice"})
    assert a.status_code == b.status_code == 202
    assert a.json()["status"] == b.json()["status"] == "queued"
    with db.connect() as conn:
        assert conn.execute("SELECT COUNT(*) FROM jobs WHERE kind='pipeline'").fetchone()[0] == 2
    assert len(list((root / "uploads").iterdir())) == 1
    drain(db)
    for response in (a, b):
        detail = client.get("/api/invoices/" + response.json()["id"]).json()
        assert detail["status"] == "completed"
        assert len(detail["runs"]) == 2
        assert all(r["status"] == "needs_review" and r["chain_outcome"] is None for r in detail["runs"])

@pytest.mark.parametrize("name,data,expected", [
    ("bad.exe", b"bad", 415), ("bad.png", b"bad", 422),
    ("bad.pdf", b"%PDF-bad", 422), ("large.png", b"x" * (5*1024*1024+1), 413),
    ("fake.jpg", image_bytes(), 422)])
def test_invalid_uploads(setup, name, data, expected):
    client, db, _ = setup
    assert client.post("/api/invoices", files={"file": (name, data)}).status_code == expected
    with db.connect() as conn:
        assert conn.execute("SELECT COUNT(*) FROM submissions").fetchone()[0] == 0


def test_valid_pdf_and_jpeg(setup):
    client, _, _ = setup
    pdf = BytesIO()
    writer = PdfWriter()
    writer.add_blank_page(width=100, height=100)
    writer.write(pdf)
    for name, content in [("invoice.pdf", pdf.getvalue()), ("invoice.jpg", image_bytes("JPEG"))]:
        assert client.post("/api/invoices", files={"file": (name, content)}).status_code == 202

@pytest.mark.parametrize("marker,status,decision,event", [
    ("paid", "paid", "submit_payment", "Paid"),
    ("blocked", "blocked", "submit_payment", "Blocked"),
    ("review", "needs_review", "review", None),
    ("failed", "failed", "error", None)])
def test_terminal_outcomes(setup, marker, status, decision, event):
    client, db, _ = setup
    sid = client.post("/api/invoices/text", json={"text": f"[mock:{marker}]"}).json()["id"]
    drain(db)
    result = client.get(f"/api/invoices/{sid}").json()
    assert result["status"] == "completed"
    for run in result["runs"]:
        assert run["status"] == status
        assert run["decision"] == decision
        assert run["tx_hash"] is None
        assert (run["chain_outcome"]["event"] if event else run["chain_outcome"]) == event


def test_pagination_and_review_filter(setup):
    client, db, _ = setup
    for marker in ("review", "paid", "review", "blocked", "review"):
        client.post("/api/invoices/text", json={"text": f"[mock:{marker}]"})
    drain(db)
    seen, cursor = [], None
    while True:
        params = {"limit": 2}
        if cursor:
            params["cursor"] = cursor
        page = client.get("/api/invoices", params=params).json()
        seen.extend(item["id"] for item in page["items"])
        cursor = page["next_cursor"]
        if cursor is None:
            break
    assert len(seen) == len(set(seen)) == 5
    review = client.get("/api/invoices?status=needs_review").json()["items"]
    assert len(review) == 3 and all(x["status"] == "completed" for x in review)
    assert client.get("/api/invoices?cursor=invalid").status_code == 422
    assert client.get("/api/invoices?limit=101").status_code == 422
    assert client.get("/api/invoices/missing").status_code == 404


def test_restart_recovery_and_stale_claim_fencing(setup):
    client, db, root = setup
    sid = client.post("/api/invoices/text", json={"text": "[mock:paid]"}).json()["id"]
    old = claim_job(db, "old", now=1)
    restarted = Database(root / "backend.sqlite3")
    new = claim_job(restarted, "new", now=100)
    assert new["id"] == old["id"] and new["attempts"] == 2
    process_pipeline(db, old)
    assert client.get(f"/api/invoices/{sid}").json()["status"] == "queued"
    process_pipeline(restarted, new)
    drain(restarted)
    assert client.get(f"/api/invoices/{sid}").json()["status"] == "completed"


def test_retry_does_not_duplicate_runs_or_payments(setup):
    client, db, _ = setup
    sid = client.post("/api/invoices/text", json={"text": "[mock:paid]"}).json()["id"]
    assert run_once(db)
    with db.connect() as conn:
        conn.execute("UPDATE jobs SET status='queued' WHERE kind='pipeline'")
    assert run_once(db)
    drain(db)
    with db.connect() as conn:
        conn.execute("UPDATE jobs SET status='queued' WHERE kind='pipeline'")
    drain(db)
    with db.connect() as conn:
        assert conn.execute("SELECT COUNT(*) FROM agent_runs WHERE submission_id=?", (sid,)).fetchone()[0] == 2
        assert conn.execute("SELECT COUNT(*) FROM jobs WHERE kind='payment' AND submission_id=?", (sid,)).fetchone()[0] == 2


def test_claim_is_atomic(setup):
    client, db, _ = setup
    client.post("/api/invoices/text", json={"text": "Invoice"})
    with ThreadPoolExecutor(max_workers=2) as pool:
        claims = list(pool.map(lambda worker: claim_job(db, worker), ["a", "b"]))
    assert sum(x is not None for x in claims) == 1


def test_failed_database_write_cleans_file(setup, monkeypatch):
    client, db, root = setup
    import app.services.invoice_service as service
    def fail(*args, **kwargs):
        raise RuntimeError("Database write failed")
    monkeypatch.setattr(service, "create_submission", fail)
    with pytest.raises(RuntimeError):
        client.post("/api/invoices", files={"file": ("invoice.png", image_bytes())})
    assert not list((root / "uploads").iterdir())


def test_queued_job_survives_restart(setup):
    client, db, root = setup
    sid = client.post("/api/invoices/text", json={"text": "[mock:review]"}).json()["id"]
    restarted = Database(root / "backend.sqlite3")
    drain(restarted)
    assert client.get(f"/api/invoices/{sid}").json()["status"] == "completed"


def test_submission_and_job_rollback_together(setup):
    client, db, _ = setup
    with db.connect() as conn:
        conn.execute("CREATE TRIGGER reject_job BEFORE INSERT ON jobs BEGIN SELECT RAISE(ABORT, 'fixture'); END")
    with pytest.raises(Exception):
        client.post("/api/invoices/text", json={"text": "Invoice"})
    with db.connect() as conn:
        assert conn.execute("SELECT COUNT(*) FROM submissions").fetchone()[0] == 0
