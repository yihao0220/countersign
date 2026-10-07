from datetime import datetime, timezone
from uuid import uuid4
from io import BytesIO
import warnings
from PIL import Image
from pypdf import PdfReader
from fastapi import HTTPException
from app.config import MAX_BYTES


def validate_document(content, filename):
    extension = filename.rsplit(".", 1)[-1].lower()
    if extension not in {"png", "jpg", "jpeg", "pdf"}:
        raise HTTPException(415, "Only PNG, JPEG and PDF are supported")
    try:
        if extension == "pdf":
            if not content.startswith(b"%PDF-"):
                raise ValueError("Invalid PDF signature")
            pdf = PdfReader(BytesIO(content), strict=True)
            if pdf.is_encrypted or not 1 <= len(pdf.pages) <= 20:
                raise ValueError("PDF must be unencrypted and contain 1-20 pages")
            for page in pdf.pages:
                _ = page.mediabox
        else:
            with warnings.catch_warnings():
                warnings.simplefilter("error", Image.DecompressionBombWarning)
                with Image.open(BytesIO(content)) as image:
                    expected = "PNG" if extension == "png" else "JPEG"
                    if image.format != expected:
                        raise ValueError("Content does not match file extension")
                    if image.width * image.height > 20_000_000:
                        raise ValueError("Image exceeds pixel limit")
                    image.verify()
    except Exception as exc:
        raise HTTPException(422, "Invalid or unsupported document") from exc
    return ".pdf" if extension == "pdf" else (".png" if extension == "png" else ".jpg")


def create_submission(db, *, nickname="", text=None, document_path=None, submission_id=None):
    sid = submission_id or uuid4().hex
    created = datetime.now(timezone.utc).isoformat(timespec="microseconds")
    with db.connect() as conn:
        conn.execute("INSERT INTO submissions(id,created_at,nickname,input_kind,document_path,text) VALUES(?,?,?,?,?,?)",
                     (sid, created, nickname, "text" if text is not None else "file", document_path, text))
        conn.execute("INSERT INTO jobs(submission_id,kind) VALUES(?, 'pipeline')", (sid,))
    return {"id": sid, "status": "queued"}


async def save_upload(db, upload_dir, file, nickname):
    content = bytearray()
    while chunk := await file.read(65536):
        content.extend(chunk)
        if len(content) > MAX_BYTES:
            raise HTTPException(413, "Maximum upload size is 5 MB")
    suffix = validate_document(bytes(content), file.filename or "")
    sid = uuid4().hex
    upload_dir.mkdir(parents=True, exist_ok=True)
    path = upload_dir / (sid + suffix)
    try:
        with path.open("xb") as stream:
            stream.write(content)
        return create_submission(db, nickname=nickname, document_path=str(path.resolve()), submission_id=sid)
    except BaseException:
        path.unlink(missing_ok=True)
        raise
