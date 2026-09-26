import { createServer } from 'node:http';
import { timingSafeEqual } from 'node:crypto';

const uuid = value => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
const exact = (body, keys) => body && !Array.isArray(body) && Object.keys(body).sort().join() === keys.sort().join();

// Single-owner, fictional-data API. Never expose Codex's administrative RPC.
export function mobileAPI({ memory, session, token }) {
  if (typeof token !== 'string' || token.length < 32) throw new Error('mobile_token_required');
  const credential = Buffer.from(`Bearer ${token}`);
  memory.db.exec(`CREATE TABLE IF NOT EXISTS mobile_requests
    (id TEXT PRIMARY KEY, text TEXT NOT NULL, status TEXT NOT NULL, answer TEXT NOT NULL, error TEXT);
    UPDATE mobile_requests SET status = 'failed', error = 'host_restarted' WHERE status = 'running';`);
  let busy = false;
  let currentWork = Promise.resolve();
  const request = id => memory.db.prepare('SELECT * FROM mobile_requests WHERE id = ?').get(id);
  const state = () => ({
    model: 'gpt-6-sol', reasoningEffort: 'medium', fictional: true, busy,
    records: memory.records(), proposal: [...memory.pending.values()][0] ?? null,
    messages: memory.db.prepare('SELECT * FROM (SELECT rowid AS sequence, * FROM mobile_requests ORDER BY rowid DESC LIMIT 30) ORDER BY sequence').all(),
  });
  const reply = (res, status, value) => {
    res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
    res.end(JSON.stringify(value));
  };
  async function body(req) {
    if (req.headers['content-type']?.split(';')[0] !== 'application/json') throw new Error('invalid_request');
    req.setEncoding('utf8');
    let data = '';
    for await (const chunk of req) {
      data += chunk;
      if (Buffer.byteLength(data) > 8192) throw new Error('invalid_request');
    }
    try { return JSON.parse(data); } catch { throw new Error('invalid_request'); }
  }
  const server = createServer(async (req, res) => {
    const supplied = Buffer.from(req.headers.authorization ?? '');
    if (supplied.length !== credential.length || !timingSafeEqual(supplied, credential)) {
      reply(res, 401, { error: 'unauthorized' }); return;
    }
    try {
      if (req.method === 'GET' && req.url === '/v1/state') return reply(res, 200, state());
      if (req.method !== 'POST') return reply(res, 404, { error: 'not_found' });
      const input = await body(req);
      if (req.url === '/v1/messages') {
        if (!exact(input, ['id', 'text']) || !uuid(input.id) || typeof input.text !== 'string'
          || !input.text.trim() || input.text.length > 2000) throw new Error('invalid_request');
        const previous = request(input.id);
        if (previous) return reply(res, previous.text === input.text ? 200 : 409,
          previous.text === input.text ? state() : { error: 'conflicting_request' });
        if (busy) return reply(res, 409, { error: 'busy' });
        memory.discard();
        memory.db.prepare('INSERT INTO mobile_requests VALUES (?, ?, ?, ?, NULL)').run(input.id, input.text, 'running', '');
        busy = true;
        currentWork = (async () => {
          let answer = '';
          const oldText = session.onText;
          session.onText = text => { answer += text; };
          try {
            await session.turn(input.text);
            memory.db.prepare("UPDATE mobile_requests SET status = 'completed', answer = ? WHERE id = ?").run(answer, input.id);
          } catch {
            memory.discard();
            memory.db.prepare("UPDATE mobile_requests SET status = 'failed', error = 'turn_failed' WHERE id = ?").run(input.id);
          } finally { session.onText = oldText; busy = false; }
        })();
        return reply(res, 202, state());
      }
      if (req.url === '/v1/confirm' || req.url === '/v1/discard') {
        if (!exact(input, ['id']) || !uuid(input.id)) throw new Error('invalid_request');
        if (busy) return reply(res, 409, { error: 'busy' });
        if (req.url === '/v1/confirm') memory.confirm(input.id);
        else {
          if (!memory.pending.has(input.id)) throw new Error('confirmation_missing_or_expired');
          memory.discard();
        }
        return reply(res, 200, state());
      }
      reply(res, 404, { error: 'not_found' });
    } catch (error) {
      const allowed = ['invalid_request', 'confirmation_missing_or_expired', 'record_changed_review_again', 'history_changed_review_again'];
      reply(res, error.message === 'invalid_request' ? 400 : 409,
        { error: allowed.includes(error.message) ? error.message : 'operation_failed' });
    }
  });
  server.requestTimeout = 15_000;
  server.headersTimeout = 10_000;
  return { server, state, settled: () => currentWork };
}
