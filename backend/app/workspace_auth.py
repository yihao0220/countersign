"""Local workspace sessions issued by the supplied Node authentication service."""
import asyncio
import json
import re
import urllib.error
import urllib.request
from urllib.parse import urlparse

from fastapi.responses import JSONResponse


def install_workspace_auth(app, url):
    endpoint = urlparse(url)
    if (endpoint.scheme != 'http' or endpoint.hostname != '127.0.0.1'
            or endpoint.username or endpoint.password or endpoint.path not in ('', '/')
            or endpoint.query or endpoint.fragment):
        raise ValueError('认证服务必须使用本机 http://127.0.0.1 地址')
    check_url = url.rstrip('/') + '/api/me'
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def verify(token):
        req = urllib.request.Request(check_url, headers={'Cookie': 'countersign_session=' + token})
        try:
            with opener.open(req, timeout=2) as response:
                user = json.load(response).get('user')
                if not isinstance(user, dict) or not all(isinstance(user.get(k), str) for k in ('id', 'name', 'email')):
                    return 503, None
                return 200, user
        except urllib.error.HTTPError as exc:
            return (401 if exc.code == 401 else 503), None
        except (OSError, ValueError):
            return 503, None

    @app.middleware('http')
    async def workspace_session(request, call_next):
        if request.url.path.startswith('/api/'):
            token = request.cookies.get('countersign_session', '')
            if not re.fullmatch(r'[a-f0-9]{64}', token):
                return JSONResponse({'detail': '请先登录工作空间'}, status_code=401, headers={'Cache-Control': 'no-store'})
            status, user = await asyncio.to_thread(verify, token)
            if status != 200:
                detail = '登录已失效，请重新登录' if status == 401 else '登录服务暂不可用，请稍后重试'
                return JSONResponse({'detail': detail}, status_code=status, headers={'Cache-Control': 'no-store'})
            request.state.workspace_user = user
        response = await call_next(request)
        if request.url.path.startswith('/api/'):
            response.headers['Cache-Control'] = 'no-store'
        return response
