from pydantic import BaseModel, Field

class TextSubmission(BaseModel):
    text: str = Field(min_length=1, max_length=100000)
    nickname: str = Field(default="", max_length=100)

class AcceptedSubmission(BaseModel):
    id: str
    status: str
