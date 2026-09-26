import test from 'node:test';
import assert from 'node:assert/strict';
import { PassThrough } from 'node:stream';
import { EventEmitter } from 'node:events';
import { Rpc } from './rpc.mjs';
import { Session } from './session.mjs';
import { createTools } from './tools.mjs';

test('RPC handles partial frames, reverse response order and server request ids', async () => {
  const input = new PassThrough(), output = new PassThrough();
  const rpc = new Rpc(input, output);
  const first = rpc.request('one'), second = rpc.request('two');
  let serverRequest;
  rpc.on('request', message => { serverRequest = message; });
  input.write('{"id":2,"res');
  input.write('ult":"second"}\n{"id":91,"method":"item/tool/call","params":{}}\n');
  input.write('{"id":1,"result":"first"}\n');
  assert.equal(await first, 'first');
  assert.equal(await second, 'second');
  assert.equal(serverRequest.id, 91);
  rpc.close();
});

test('RPC disconnect rejects outstanding work; timeout never retries', async () => {
  const input = new PassThrough(), output = new PassThrough();
  const rpc = new Rpc(input, output, { timeoutMs: 10 });
  let sent = '';
  output.on('data', chunk => { sent += chunk; });
  await assert.rejects(rpc.request('write'), /request_timeout/);
  assert.equal(sent.trim().split('\n').length, 1);
  assert.equal(rpc.closed, true);
  await assert.rejects(rpc.request('again'), /connection_closed/);
  const next = new Rpc(new PassThrough(), new PassThrough());
  const pending = next.request('pending');
  next.close();
  await assert.rejects(pending, /connection_closed/);
});

test('RPC rejects malformed or oversized frames without surfacing their contents', async () => {
  for (const message of ['secret-not-json\n', 'x'.repeat(33)]) {
    const input = new PassThrough();
    const rpc = new Rpc(input, new PassThrough(), { maxFrameBytes: 32 });
    const pending = rpc.request('test');
    input.write(message);
    await assert.rejects(pending, /^Error: connection_closed$/);
  }
});

test('read-only fixtures distinguish shops, return both candidates and no fabricated match', async () => {
  const tools = createTools();
  const both = await tools('search_memory', { query: '麻薯' });
  assert.deepEqual(both.records.map(m => m.id), ['fixture-hema', 'fixture-sams']);
  assert.match(both.records[0].text, /6 个/);
  assert.match(both.records[1].text, /18 个/);
  assert.deepEqual((await tools('search_memory', { query: '山姆' })).records.map(m => m.id), ['fixture-sams']);
  assert.deepEqual((await tools('search_memory', { query: '不存在的东西' })).records, []);
  await assert.rejects(tools('write_memory', {}), /unknown_tool/);
  await assert.rejects(tools('search_memory', { query: '麻薯', path: '/etc/passwd' }), /invalid_arguments/);
});

const args = { text: '盒马麻薯放哪里', candidateIds: ['fixture-sams', 'fixture-hema'] };
const valid = {
  model: 'jev-1.13.0', answers: {
    'fixture-hema': { type: 'noul', noul: 0.93 },
    'fixture-sams': { type: 'noul', noul: 0.12 },
  }, usage: { input_tokens: 512, output_tokens: 0 },
};

test('Jev sends explicit candidate context and returns independent probabilities without deleting candidates', async () => {
  let body;
  const tools = createTools({ apiKey: 'test-secret', allowJev: true, fetchImpl: async (url, options) => {
    assert.equal(url, 'https://api.typesafe.ai/v1/systemone');
    assert.equal(options.headers.Authorization, 'Bearer test-secret');
    body = JSON.parse(options.body);
    return { ok: true, json: async () => valid };
  } });
  const result = await tools('judge_conditions', args);
  assert.equal(body.questions['fixture-hema'].instructions.candidate.shop, '盒马');
  assert.equal(body.questions['fixture-sams'].instructions.candidate.shop, '山姆');
  assert.equal(body.state.request, args.text);
  assert.deepEqual(result.judgments, [
    { memoryId: 'fixture-hema', relevanceProbability: 0.93 },
    { memoryId: 'fixture-sams', relevanceProbability: 0.12 },
  ]);
  assert.equal(result.usage.input_tokens, 512);
});

test('Jev requires spending opt-in, key and valid candidate IDs before any network request', async () => {
  const fetchImpl = () => { assert.fail('must not make network request'); };
  await assert.rejects(createTools({ fetchImpl })('judge_conditions', args), /spending_not_enabled/);
  await assert.rejects(createTools({ fetchImpl, allowJev: true })('judge_conditions', args), /not_configured/);
  const tools = createTools({ fetchImpl, allowJev: true, apiKey: 'test' });
  for (const candidateIds of [[], ['invented'], ['fixture-hema', 'fixture-hema']]) {
    await assert.rejects(tools('judge_conditions', { ...args, candidateIds }), /invalid_arguments/);
  }
});

test('Jev rejects partial, extra, wrong-type and out-of-range answers', async () => {
  const cases = [
    { ...valid, answers: { 'fixture-hema': valid.answers['fixture-hema'] } },
    { ...valid, answers: { ...valid.answers, extra: { type: 'noul', noul: 0.9 } } },
    { ...valid, answers: { ...valid.answers, 'fixture-sams': { type: 'noul', noul: 1.01 } } },
    { ...valid, answers: { ...valid.answers, 'fixture-sams': { type: 'noul', noul: '0.5' } } },
    { ...valid, model: 'unknown' },
    { ...valid, usage: { input_tokens: -1, output_tokens: 0 } },
  ];
  for (const data of cases) {
    const tools = createTools({ allowJev: true, apiKey: 'test', fetchImpl: async () => ({ ok: true, json: async () => data }) });
    await assert.rejects(tools('judge_conditions', args), /jev_invalid_response/);
  }
});

test('Jev HTTP failure is sanitized, not retried, and counts against session cap', async () => {
  let calls = 0;
  const tools = createTools({ allowJev: true, apiKey: 'secret', maxCalls: 1, fetchImpl: async () => {
    calls++;
    return { ok: false, status: 429, json: async () => ({ secret: 'do not print' }) };
  } });
  await assert.rejects(tools('judge_conditions', args), /^Error: jev_http_429$/);
  await assert.rejects(tools('judge_conditions', args), /session_call_limit/);
  assert.equal(calls, 1);
});

test('Jev supports timeout and turn cancellation without reporting success', async () => {
  const fetchImpl = async (_, { signal }) => new Promise((resolve, reject) => {
    signal.addEventListener('abort', () => reject(signal.reason), { once: true });
  });
  // AbortSignal.timeout is unref'd; keep the test process alive while it fires.
  const keepAlive = setTimeout(() => {}, 1000);
  try {
    const tools = createTools({ apiKey: 'test', allowJev: true, timeoutMs: 10, fetchImpl });
    await assert.rejects(tools('judge_conditions', args), /jev_timeout/);
    const controller = new AbortController();
    const pending = tools('judge_conditions', args, controller.signal);
    controller.abort();
    await assert.rejects(pending, /cancelled/);
  } finally { clearTimeout(keepAlive); }
});

class FakeRpc extends EventEmitter {
  sent = [];
  closed = false;
  async request(method, params) {
    this.sent.push({ method, params });
    if (method === 'thread/start') return { thread: { id: 'thread-a' }, sandbox: { type: 'readOnly' }, approvalPolicy: 'never', model: 'gpt-6-sol', reasoningEffort: 'medium' };
    if (method === 'turn/start') {
      this.emit('notification', { method: 'turn/started', params: { threadId: 'thread-a', turn: { id: 'turn-a' } } });
      return { turn: { id: 'turn-a' } };
    }
    return {};
  }
  send(message) { this.sent.push(message); }
  close() { this.closed = true; this.emit('closed'); }
}

function complete(rpc, status = 'completed') {
  rpc.emit('notification', { method: 'turn/completed', params: { threadId: 'thread-a', turn: { id: 'turn-a', status } } });
}

const call = (id, overrides = {}) => ({ id, method: 'item/tool/call', params: {
  threadId: 'thread-a', turnId: 'turn-a', callId: 'call-a', namespace: null,
  tool: 'search_memory', arguments: { query: '山姆' }, ...overrides,
} });

test('session config removes environment; turn waits for completion and ignores other threads', async () => {
  const rpc = new FakeRpc();
  const texts = [];
  const session = new Session(rpc, createTools(), { onText: text => texts.push(text) });
  await session.initialize();
  await session.start('/isolated');
  const params = rpc.sent.find(m => m.method === 'thread/start').params;
  assert.deepEqual(params.environments, []);
  assert.equal(params.config['features.shell_tool'], false);
  assert.equal(params.sandbox, 'read-only');
  assert.equal(params.model, 'gpt-6-sol');
  assert.equal(params.allowProviderModelFallback, false);
  assert.equal(params.config.model_reasoning_effort, 'medium');
  const pending = session.turn('麻薯');
  const turnParams = rpc.sent.find(m => m.method === 'turn/start').params;
  assert.equal(turnParams.model, 'gpt-6-sol');
  assert.equal(turnParams.effort, 'medium');
  await assert.rejects(session.turn('overlap'), /not_ready/);
  rpc.emit('notification', { method: 'turn/completed', params: { threadId: 'other', turn: { id: 'turn-a', status: 'completed' } } });
  assert.ok(session.active);
  rpc.emit('notification', { method: 'item/agentMessage/delta', params: { threadId: 'thread-a', turnId: 'turn-a', delta: '测试资料' } });
  complete(rpc);
  await pending;
  assert.deepEqual(texts, ['测试资料']);
});

test('session rejects a different model, effort or missing effort before sending a turn', async () => {
  for (const override of [{ model: 'gpt-6-astra' }, { reasoningEffort: 'high' }, { reasoningEffort: null }]) {
    const rpc = new FakeRpc();
    const original = rpc.request.bind(rpc);
    rpc.request = async (method, params) => ({ ...await original(method, params), ...override });
    const session = new Session(rpc, createTools());
    await assert.rejects(session.start('/isolated'), /model_or_effort_mismatch/);
    await assert.rejects(session.turn('测试'), /session_not_ready/);
    assert.equal(rpc.sent.some(m => m.method === 'turn/start'), false);
  }
});

test('duplicate concurrent tool calls execute once, conflicting replay and wrong thread denied', async () => {
  const rpc = new FakeRpc();
  let executions = 0;
  const session = new Session(rpc, async () => { executions++; return { source: 'test' }; });
  await session.start('/isolated');
  const pending = session.turn('测试');
  await Promise.all([session.handleRequest(call(70)), session.handleRequest(call(71))]);
  assert.equal(executions, 1);
  assert.equal(rpc.sent.find(m => m.id === 70).result.success, true);
  assert.equal(rpc.sent.find(m => m.id === 71).result.success, true);
  await session.handleRequest(call(72, { arguments: { query: '盒马' } }));
  await session.handleRequest(call(73, { threadId: 'other' }));
  assert.match(rpc.sent.find(m => m.id === 72).result.contentItems[0].text, /conflicting_tool_replay/);
  assert.equal(rpc.sent.find(m => m.id === 73).result.success, false);
  assert.equal(executions, 1);
  complete(rpc); await pending;
});

test('tool failure returns unsuccessful result and does not kill main conversation', async () => {
  const rpc = new FakeRpc();
  const session = new Session(rpc, createTools());
  await session.start('/isolated');
  const pending = session.turn('比较记忆');
  await session.handleRequest(call(80, { tool: 'judge_conditions', arguments: args }));
  assert.equal(rpc.sent.find(m => m.id === 80).result.success, false);
  assert.ok(session.active);
  await session.handleRequest({ id: 81, method: 'item/commandExecution/requestApproval', params: {} });
  assert.deepEqual(rpc.sent.find(m => m.id === 81).result, { decision: 'decline' });
  complete(rpc); await pending;
});

test('cancel interrupts correct turn, aborts tool work, waits for terminal notification', async () => {
  const rpc = new FakeRpc();
  const session = new Session(rpc, createTools());
  await session.start('/isolated');
  const pending = session.turn('测试');
  const rejection = assert.rejects(pending, /turn_interrupted/);
  const signal = session.active.controller.signal;
  await session.cancel();
  assert.equal(signal.aborted, true);
  assert.deepEqual(rpc.sent.find(m => m.method === 'turn/interrupt').params, { threadId: 'thread-a', turnId: 'turn-a' });
  assert.ok(session.active);
  complete(rpc, 'interrupted');
  await rejection;
});

test('disconnect after starting a turn reports unknown status rather than replaying', async () => {
  const rpc = new FakeRpc();
  const session = new Session(rpc, createTools());
  await session.start('/isolated');
  const pending = session.turn('测试');
  rpc.close();
  await assert.rejects(pending, /execution_status_unknown/);
  assert.equal(rpc.sent.filter(m => m.method === 'turn/start').length, 1);
});

test('cancel rejects newly arriving tools and late success from an in-flight tool', async () => {
  const rpc = new FakeRpc();
  let resolveTool, executions = 0;
  const session = new Session(rpc, async () => {
    executions++;
    return new Promise(resolve => { resolveTool = resolve; });
  });
  await session.start('/isolated');
  const pending = session.turn('测试');
  const rejection = assert.rejects(pending, /turn_interrupted/);
  const oldTool = session.handleRequest(call(91));
  await session.cancel();
  await session.handleRequest(call(92, { callId: 'new-call' }));
  resolveTool({ source: 'test' });
  await oldTool;
  assert.equal(executions, 1);
  assert.equal(rpc.sent.find(m => m.id === 91).result.success, false);
  assert.equal(rpc.sent.find(m => m.id === 92).result.success, false);
  complete(rpc, 'interrupted'); await rejection;
});

test('late completed notification cannot finish the next turn', async () => {
  const rpc = new FakeRpc();
  const session = new Session(rpc, createTools());
  await session.start('/isolated');
  const first = session.turn('第一轮');
  complete(rpc); await first;
  const original = rpc.request.bind(rpc);
  rpc.request = async (method, params) => {
    if (method === 'turn/start') {
      complete(rpc); // Old event arrives before the new start acknowledgement.
      return { turn: { id: 'turn-b' } };
    }
    return original(method, params);
  };
  const second = session.turn('第二轮');
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(session.active.id, 'turn-b');
  rpc.emit('notification', { method: 'turn/completed', params: { threadId: 'thread-a', turn: { id: 'turn-b', status: 'completed' } } });
  await second;
});
