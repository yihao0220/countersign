"""Exercise the actual supplied Node sessions at the Python API boundary."""
import json
import os
from pathlib import Path
import secrets
import shutil
import socket
import subprocess
import time

import httpx
import pytest
from fastapi import Request
from fastapi.testclient import TestClient

from app.main import create_app


@pytest.fixture
def authentication(tmp_path):
    node = shutil.which('node') or str(Path.home() / '.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node')
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    base = f'http://127.0.0.1:{port}'
    env = dict(os.environ, PORT=str(port), HOST='127.0.0.1', APP_ORIGIN=base, SECURE_COOKIES='false', DATA_DIR=str(tmp_path/'accounts'))
    process = subprocess.Popen([node, str(Path(__file__).resolve().parents[2]/'auth/server.mjs')], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        with httpx.Client(base_url=base, trust_env=False, timeout=2) as client:
            for _ in range(100):
                try:
                    if client.get('/api/auth-health').status_code == 200:
                        break
                except httpx.HTTPError:
                    pass
                if process.poll() is not None:
                    pytest.fail('认证服务提前退出')
                time.sleep(.05)
            else:
                pytest.fail('认证服务未就绪')
            yield client, base, process
    finally:
        if process.poll() is None:
            process.terminate()
        process.wait(timeout=5)


def test_real_session_protects_read_write_logout_and_service_failure(authentication, tmp_path, monkeypatch):
    auth, url, process = authentication
    monkeypatch.setenv('COUNTERSIGN_AUTH_URL', url)
    monkeypatch.delenv('COUNTERSIGN_LOCAL_MANIFEST', raising=False)
    app = create_app(tmp_path/'backend')
    writes = []

    @app.get('/api/session-test')
    def read(request: Request):
        return {'user': request.state.workspace_user}

    @app.post('/api/session-test')
    def write(request: Request):
        writes.append(request.state.workspace_user['id'])
        return {'ok': True}

    with TestClient(app) as client:
        assert client.get('/health').json()['workspace_auth'] is True
        assert client.get('/api/session-test').status_code == 401
        assert client.post('/api/session-test').status_code == 401
        assert client.post('/api/invoices').status_code == 401
        assert client.get('/api/session-test', headers={'Cookie': 'countersign_session='+'a'*64}).status_code == 401
        assert writes == []
        account = {'name':'测试账户', 'email':'session@example.test', 'password':secrets.token_urlsafe(24)}
        created = auth.post('/api/register', json=account, headers={'Origin':url})
        assert created.status_code == 201
        cookie = created.headers['set-cookie'].split(';')[0]
        client.headers['Cookie'] = cookie
        valid = client.get('/api/session-test')
        assert valid.status_code == 200
        assert valid.json()['user']['email'] == account['email']
        assert valid.headers['cache-control'] == 'no-store'
        assert set(valid.json()['user']) == {'id','name','email'}
        assert client.post('/api/session-test').status_code == 200
        assert len(writes) == 1
        assert auth.post('/api/logout', json={}, headers={'Origin':url}).status_code == 200
        assert client.get('/api/session-test').status_code == 401
        assert client.post('/api/session-test').status_code == 401
        assert len(writes) == 1
        logged_in = auth.post('/api/login', json=account, headers={'Origin':url})
        assert logged_in.status_code == 200
        client.headers['Cookie'] = logged_in.headers['set-cookie'].split(';')[0]
        assert client.get('/api/session-test').status_code == 200
        process.terminate(); process.wait(timeout=5)
        assert client.get('/api/session-test').status_code == 503
        assert client.post('/api/session-test').status_code == 503
        assert len(writes) == 1
        disk = json.loads((tmp_path/'accounts/users.json').read_text())
        assert 'password' not in disk[0]
        assert account['password'] not in (tmp_path/'accounts/users.json').read_text()


@pytest.mark.parametrize('url', ['https://example.com', 'http://localhost:3000', 'http://127.0.0.1:3000/api/me', 'http://127.0.0.1:3000/?x=1'])
def test_auth_rejects_non_loopback_or_ambiguous_service_urls(url, tmp_path, monkeypatch):
    monkeypatch.setenv('COUNTERSIGN_AUTH_URL', url)
    with pytest.raises(ValueError, match='本机'):
        create_app(tmp_path)
