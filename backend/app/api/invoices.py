import base64
import json
from fastapi import APIRouter, File, Form, HTTPException, Query, Request, UploadFile
from app.schemas import AcceptedSubmission, TextSubmission
from app.services.invoice_service import create_submission, save_upload

router = APIRouter(prefix="/api/invoices", tags=["invoices"])

@router.post("", status_code=202, response_model=AcceptedSubmission)
async def upload(request: Request, file: UploadFile = File(...), nickname: str = Form("", max_length=100)):
    try:
        return await save_upload(request.app.state.db, request.app.state.upload_dir, file, nickname)
    finally:
        await file.close()

@router.post("/text", status_code=202, response_model=AcceptedSubmission)
def submit_text(body: TextSubmission, request: Request):
    if not body.text.strip():
        raise HTTPException(422, "Text must not be blank")
    return create_submission(request.app.state.db, text=body.text, nickname=body.nickname)

@router.get("")
def inbox(request: Request, limit: int = Query(20, ge=1, le=100), cursor: str | None = None,
          status: str | None = Query(None, pattern="^(queued|extracting|evaluating|completed|failed|needs_review)$")):
    clauses, args = [], []
    if status == "needs_review":
        clauses.append("EXISTS (SELECT 1 FROM agent_runs r WHERE r.submission_id=s.id AND r.status='needs_review')")
    elif status:
        clauses.append("s.status=?")
        args.append(status)
    if cursor:
        try:
            created, sid = json.loads(base64.urlsafe_b64decode(cursor.encode()).decode())
            if not isinstance(created, str) or not isinstance(sid, str):
                raise ValueError()
        except Exception as exc:
            raise HTTPException(422, "Invalid cursor") from exc
        clauses.append("(s.created_at,s.id) < (?,?)")
        args.extend([created, sid])
    where = " WHERE " + " AND ".join(clauses) if clauses else ""
    with request.app.state.db.connect() as conn:
        rows = conn.execute("SELECT s.* FROM submissions s" + where + " ORDER BY s.created_at DESC,s.id DESC LIMIT ?", args + [limit + 1]).fetchall()
    items = []
    for row in rows[:limit]:
        extracted = json.loads(row["extracted"] or "{}")
        items.append({"id": row["id"], "created_at": row["created_at"], "status": row["status"],
                      "vendor": extracted.get("vendor_name"), "amount": extracted.get("amount"), "currency": extracted.get("currency")})
    next_cursor = None
    if len(rows) > limit:
        last = rows[limit - 1]
        next_cursor = base64.urlsafe_b64encode(json.dumps([last["created_at"], last["id"]]).encode()).decode()
    return {"items": items, "next_cursor": next_cursor}

@router.get("/{submission_id}")
def detail(submission_id: str, request: Request):
    with request.app.state.db.connect() as conn:
        row = conn.execute("SELECT * FROM submissions WHERE id=?", (submission_id,)).fetchone()
        if row is None:
            raise HTTPException(404, "Invoice not found")
        runs = conn.execute("SELECT * FROM agent_runs WHERE submission_id=? ORDER BY agent", (submission_id,)).fetchall()
    return {"id": row["id"], "created_at": row["created_at"], "status": row["status"], "error": row["error"],
            "extracted": json.loads(row["extracted"]) if row["extracted"] else None,
            "runs": [{"agent": run["agent"], "guard_version": run["guard_version"], "status": run["status"],
                      "flags": json.loads(run["flags"]), "decision": run["decision"], "tx_hash": run["tx_hash"],
                      "chain_outcome": json.loads(run["chain_outcome"]) if run["chain_outcome"] else None} for run in runs]}
