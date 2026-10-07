from pathlib import Path
import os

DATA_DIR = Path(os.getenv("BACKEND_DATA_DIR", "var"))
MAX_BYTES = 5 * 1024 * 1024
LEASE_SECONDS = 60
AGENTS = ("guarded", "naive")
GUARD_VERSION = "mock-v1"
