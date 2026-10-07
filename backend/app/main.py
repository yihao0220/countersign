from pathlib import Path
import os
from urllib.parse import urlparse
from fastapi import FastAPI
from fastapi.responses import JSONResponse
from app.api.invoices import router
from app.config import DATA_DIR
from app.db import Database

def create_app(data_dir=None):
    root = Path(data_dir or DATA_DIR)
    app = FastAPI(title="Countersign Backend", version="0.1.0")
    app.state.db = Database(root / "backend.sqlite3")
    app.state.upload_dir = root / "uploads"
    app.include_router(router)
    manifest = os.environ.get('COUNTERSIGN_LOCAL_MANIFEST')
    if manifest:
        from app.chain.local import LocalChain
        from app.api.local import router as local_router, initialize
        app.state.local_chain = LocalChain(manifest)
        initialize(app.state.db)
        app.include_router(local_router)

        @app.middleware('http')
        async def local_boundary(request, call_next):
            # The no-auth owner shortcut is only for this loopback-only test version.
            host = request.headers.get('host', '').split(':')[0]
            origin = request.headers.get('origin')
            allowed = {app.state.local_chain.manifest['frontend_url'], 'http://127.0.0.1:8000'}
            if host not in ('127.0.0.1', 'localhost') or (origin and origin not in allowed):
                return JSONResponse({'detail':'本地测试版仅接受本机页面请求'}, status_code=403)
            if request.headers.get('sec-fetch-site') == 'cross-site':
                return JSONResponse({'detail':'不接受跨站请求'}, status_code=403)
            return await call_next(request)
    return app

app = create_app()
