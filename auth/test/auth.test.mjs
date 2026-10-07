import { test } from 'node:test';
import { randomBytes } from 'node:crypto';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createApp } from '../server.mjs';

async function fixture(t, options = {}) {
  const dataDir = await mkdtemp(join(tmpdir(), 'countersign-test-'));
  const server = await createApp({ dataDir, ...options });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  t.after(async () => { await new Promise(resolve => server.close(resolve)); await rm(dataDir, { recursive: true, force: true }); });
  const request = (path, data, cookie, origin = base) => fetch(base + path, {
    method: data === undefined ? 'GET' : 'POST',
    headers: { ...(data === undefined ? {} : { Origin: origin, 'Content-Type': 'application/json' }), ...(cookie ? { Cookie: cookie } : {}) },
    body: data === undefined ? undefined : JSON.stringify(data),
  });
  return { request, dataDir, base, server };
}
const account = { name: 'Alex Chen', email: 'Alex@example.com', password: randomBytes(24).toString('hex') };

test('registration, persistent password hashing, login, session rotation and logout', async t => {
  const { request, dataDir } = await fixture(t);
  assert.equal((await request('/api/me')).status, 401);
  const registered = await request('/api/register', account);
  assert.equal(registered.status, 201);
  const user = (await registered.json()).user;
  assert.deepEqual(Object.keys(user).sort(), ['email', 'id', 'name']);
  assert.equal(user.email, 'alex@example.com');
  const cookie = registered.headers.get('set-cookie');
  assert.match(cookie, /HttpOnly; SameSite=Strict/);
  const disk = await readFile(join(dataDir, 'users.json'), 'utf8');
  assert.ok(!disk.includes(account.password));
  assert.equal(JSON.parse(disk)[0].passwordHash.length, 128);
  assert.equal((await request('/api/me', undefined, cookie)).status, 200);
  assert.equal((await request('/api/login', { ...account, password: 'incorrect-password' })).status, 401);
  assert.equal((await request('/api/login', { ...account, email: 'unknown@example.com' })).status, 401);
  const loggedIn = await request('/api/login', account, cookie);
  assert.equal(loggedIn.status, 200);
  const newCookie = loggedIn.headers.get('set-cookie');
  assert.notEqual(cookie, newCookie);
  assert.equal((await request('/api/me', undefined, cookie)).status, 401);
  assert.equal((await request('/api/logout', {}, newCookie)).status, 200);
  assert.equal((await request('/api/me', undefined, newCookie)).status, 401);
  assert.equal((await request('/api/me', undefined, 'countersign_session=forged')).status, 401);
});

test('rejects invalid input, duplicate accounts, cross-origin writes and private-file access', async t => {
  const { request, base } = await fixture(t);
  assert.equal((await request('/api/register', { ...account, password: 'short' })).status, 400);
  assert.equal((await request('/api/register', { ...account, email: 'invalid' })).status, 400);
  assert.equal((await request('/api/register', { ...account, name: 'a' })).status, 400);
  assert.equal((await request('/api/register', account, undefined, 'https://evil.example')).status, 403);
  assert.equal((await request('/api/register', account)).status, 201);
  assert.equal((await request('/api/register', { ...account, email: 'alex@example.com' })).status, 409);
  assert.equal((await fetch(base + '/data/users.json')).status, 404);
  assert.equal((await fetch(base + '/server.mjs')).status, 404);
  const page = await fetch(base + '/api/auth-health');
  assert.equal(page.status, 200);
  assert.match(page.headers.get('content-security-policy'), /frame-ancestors 'none'/);
});

test('concurrent registration cannot create duplicate email records', async t => {
  const { request, dataDir } = await fixture(t);
  const responses = await Promise.all([request('/api/register', account), request('/api/register', account)]);
  assert.deepEqual(responses.map(r => r.status).sort(), [201, 409]);
  assert.equal(JSON.parse(await readFile(join(dataDir, 'users.json'), 'utf8')).length, 1);
});

test('limits authentication attempts before further password checks', async t => {
  const { request } = await fixture(t);
  for (let i = 0; i < 20; i++) assert.equal((await request('/api/login', { email: 'invalid', password: 'short' })).status, 400);
  const blocked = await request('/api/login', account);
  assert.equal(blocked.status, 429);
  assert.ok(Number(blocked.headers.get('retry-after')) > 0);
});

test('HTTPS deployment configuration issues Secure cookies', async t => {
  const { request } = await fixture(t, { origin: 'https://countersign.example', secureCookies: true });
  const registered = await request('/api/register', account, undefined, 'https://countersign.example');
  assert.equal(registered.status, 201);
  assert.match(registered.headers.get('set-cookie'), /; Secure/);
});

test('accounts survive a restart while old sessions expire', async t => {
  const first = await fixture(t);
  const registered = await first.request('/api/register', account);
  assert.equal(registered.status, 201);
  const oldCookie = registered.headers.get('set-cookie');
  await new Promise(resolve => first.server.close(resolve));
  const restarted = await createApp({ dataDir: first.dataDir });
  await new Promise(resolve => restarted.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => restarted.close(resolve)));
  const base = `http://127.0.0.1:${restarted.address().port}`;
  assert.equal((await fetch(base + '/api/me', { headers: { Cookie: oldCookie } })).status, 401);
  const login = await fetch(base + '/api/login', {
    method: 'POST', headers: { Origin: base, 'Content-Type': 'application/json' }, body: JSON.stringify(account),
  });
  assert.equal(login.status, 200);
  const current = await fetch(base + '/api/me', { headers: { Cookie: login.headers.get('set-cookie') } });
  assert.equal(current.status, 200);
});
