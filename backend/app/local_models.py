from typing import Literal, Any
from pydantic import BaseModel, Field, StrictInt

class Step(BaseModel):
    name: Literal['extract','hidden_text','match','guard','chain']
    status: Literal['pending','running','done','skipped','failed']
    detail: str | None = None

class Flag(BaseModel):
    code: str
    severity: Literal['high','medium','low']
    detail_en: str
    detail_zh: str

class Proposal(BaseModel):
    vendor_id: int
    vendor_name: str
    pay_to: str
    registry_payout: str
    po_id: int
    po_ref: str
    amount: str
    invoice_hash: str

class TxInfo(BaseModel):
    hash: str
    explorer_url: str
    event: Literal['Paid','Blocked']
    reason: str | None
    reason_code: int | None = Field(default=None, ge=0, le=13)
    reason_label_en: str | None
    reason_label_zh: str | None
    network: Literal['local'] = 'local'

class Attempt(BaseModel):
    id: str
    status: Literal['queued','extracting','checking','deciding','sending','done','error']
    outcome: Literal['paid','blocked','refused','no_invoice','error'] | None
    agent: Literal['guarded','naive']
    source: Literal['bounty','seed','team','batch']
    nickname: str = ''
    input_kind: Literal['pdf','image','text']
    file_name: str | None = None
    preview_url: str | None = None
    steps: list[Step]
    extraction: dict[str, Any] | None = None
    hidden_text: dict[str, Any] | None = None
    flags: list[Flag]
    proposal: Proposal | None = None
    tx: TxInfo | None = None
    ai_fooled: bool = False
    created_at: str
    latency_ms: int | None = None
    local_fixture: bool = True
    message: str | None = None

class Accepted(BaseModel):
    attempt_id: str

class LocalAction(BaseModel):
    type: Literal['pause','deactivateVendor','closePO','revokeAgent','lowerDailyCap','lowerTotalBudget','lowerPOBudget','execute','cancel','queue']
    vendorId: int | None = Field(default=None,strict=True,ge=1,le=2**53-1)
    poId: int | None = Field(default=None,strict=True,ge=1,le=2**53-1)
    agent: str | None = None
    cap: str | None = None
    id: str | None = None
    kind: Literal['SetPayout','Unpause','RaiseDailyCap','RaiseTotalBudget','RaisePOBudget','AddAgent','AddVendor','AddPO','Withdraw'] | None = None
    decoded: dict[str, str | StrictInt] = Field(default_factory=dict)
