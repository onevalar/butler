import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { randomUUID } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { MemoryStore } from './memory.mjs';
import { mobileAPI } from './mobile-api.mjs';

const token = 'fictional-test-token-not-a-real-secret';
const purchase = { action: 'purchase', subject: '麻薯', shop: '盒马', quantity: 6, unit: '个', location: '冰箱上层', expiryDate: null };
async function serve(memory, session) {
  const api = mobileAPI({ memory, session, token });
  api.server.listen(0, '127.0.0.1'); await once(api.server, 'listening');
  const url = `http://127.0.0.1:${api.server.address().port}`;
  return { ...api, async call(path = '/v1/state', body, key = token) {
    const response = await fetch(url + path, { method: body === undefined ? 'GET' : 'POST',
      headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
      body: body === undefined ? undefined : JSON.stringify(body) });
    return { status: response.status, value: await response.json() };
  }, async close() { await api.settled(); await new Promise(resolve => api.server.close(resolve)); } };
}

test('mobile API denies unauthenticated access and exposes no administrative RPC', async () => {
  const memory = new MemoryStore(':memory:');
  const api = await serve(memory, { async turn() { assert.fail('not a model request'); } });
  try {
    assert.equal((await api.call('/v1/state', undefined, 'wrong')).status, 401);
    assert.equal((await api.call('/thread/start', {})).status, 404);
    assert.equal((await api.call('/v1/messages', { id: randomUUID(), text: '   ' })).status, 400);
    assert.equal((await api.call('/v1/messages', { id: randomUUID(), text: '测试', extra: true })).status, 400);
    const response = await api.call();
    assert.equal(response.value.fictional, true);
    assert.deepEqual(response.value.records, []);
  } finally { await api.close(); memory.close(); }
});

test('mobile messages are deduplicated while running, and confirm writes only once', async () => {
  const memory = new MemoryStore(':memory:');
  let release, calls = 0;
  const session = { async turn(text) {
    calls++;
    await new Promise(resolve => { release = resolve; });
    memory.propose(purchase, text);
    this.onText('待确认，不是已保存');
  } };
  const api = await serve(memory, session);
  try {
    const message = { id: randomUUID(), text: '盒马麻薯六个' };
    assert.equal((await api.call('/v1/messages', message)).status, 202);
    assert.equal((await api.call('/v1/messages', message)).status, 200);
    assert.equal((await api.call('/v1/messages', { ...message, text: '不同内容' })).status, 409);
    assert.equal((await api.call('/v1/messages', { id: randomUUID(), text: '另一条' })).status, 409);
    assert.equal((await api.call('/v1/confirm', { id: randomUUID() })).status, 409);
    release(); await api.settled();
    const state = (await api.call()).value;
    assert.equal(calls, 1); assert.deepEqual(state.records, []);
    assert.equal(state.messages[0].answer, '待确认，不是已保存');
    const id = state.proposal.id;
    assert.equal((await api.call('/v1/confirm', { id })).value.records[0].quantity, 6);
    assert.equal((await api.call('/v1/confirm', { id })).status, 200);
    assert.equal(memory.history().length, 1);
    assert.equal((await api.call('/v1/messages', message)).value.proposal, null);
    assert.equal(calls, 1);
  } finally { release?.(); await api.close(); memory.close(); }
});

test('stale discard cannot delete a replacement preview; failed turns remove drafts', async () => {
  const memory = new MemoryStore(':memory:');
  const session = { async turn(text) {
    memory.propose(purchase, text);
    if (text === '失败') throw new Error('private backend detail');
    this.onText('预览');
  } };
  const api = await serve(memory, session);
  try {
    await api.call('/v1/messages', { id: randomUUID(), text: '第一条' }); await api.settled();
    const old = api.state().proposal.id;
    await api.call('/v1/messages', { id: randomUUID(), text: '纠正' }); await api.settled();
    const current = api.state().proposal.id;
    assert.equal((await api.call('/v1/discard', { id: old })).status, 409);
    assert.equal(api.state().proposal.id, current);
    assert.equal((await api.call('/v1/discard', { id: current })).value.proposal, null);
    await api.call('/v1/messages', { id: randomUUID(), text: '失败' }); await api.settled();
    assert.equal(api.state().proposal, null);
    assert.equal(api.state().messages.at(-1).error, 'turn_failed');
    assert.deepEqual(memory.records(), []);
  } finally { await api.close(); memory.close(); }
});

test('restart preserves message receipts and records, expires previews and marks interrupted work', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'butler-api-'));
  const path = join(dir, 'test.sqlite');
  let memory = new MemoryStore(path);
  let api = await serve(memory, { async turn(text) { memory.propose(purchase, text); this.onText('预览'); } });
  try {
    const message = { id: randomUUID(), text: '六个麻薯' };
    await api.call('/v1/messages', message); await api.settled();
    const confirmation = api.state().proposal.id;
    await api.call('/v1/confirm', { id: confirmation });
    const interrupted = randomUUID();
    memory.db.prepare('INSERT INTO mobile_requests VALUES (?, ?, ?, ?, NULL)').run(interrupted, '未完成', 'running', '');
    await api.close(); memory.close();
    memory = new MemoryStore(path);
    api = await serve(memory, { async turn() { assert.fail('must not replay after restart'); } });
    assert.equal((await api.call('/v1/messages', message)).status, 200);
    assert.equal((await api.call('/v1/confirm', { id: confirmation })).value.records.length, 1);
    assert.equal(api.state().proposal, null);
    assert.equal(api.state().messages.at(-1).error, 'host_restarted');
    assert.equal(memory.history().length, 1);
  } finally { await api.close(); memory.close(); rmSync(dir, { recursive: true, force: true }); }
});
