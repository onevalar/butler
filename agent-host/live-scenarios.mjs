// Explicit, billable Codex evaluation with disposable fictional data. Never run by npm test.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { MemoryStore } from './memory.mjs';
import { createTools } from './tools.mjs';
import { Rpc } from './rpc.mjs';
import { Session } from './session.mjs';

if (process.argv[2] !== '--live') throw new Error('Run with --live only after authorizing Codex subscription usage. Jev stays disabled.');
process.umask(0o077);
const root = fileURLToPath(new URL('.', import.meta.url));
const home = join(root, '.local/home');
const dir = await mkdtemp(join(tmpdir(), 'butler-live-'));
const memory = new MemoryStore(join(dir, 'fictional.sqlite'));
const seed = args => memory.confirm(memory.propose(args, '虚构测试夹具').proposal.id).recordId;
const habit = seed({ action: 'remember', subject: '麻薯', shop: '盒马', text: '通常买小盒，每盒6个，放冰箱上层。' });
const hema = seed({ action: 'purchase', subject: '麻薯', shop: '盒马', quantity: 6, unit: '个', location: '冰箱上层', expiryDate: '2026-10-02' });
const sams = seed({ action: 'purchase', subject: '麻薯', shop: '山姆', quantity: 18, unit: '个', location: '冰箱下层', expiryDate: '2026-10-05' });
const child = spawn(join(root, 'node_modules/.bin/codex'), ['app-server', '--listen', 'stdio://',
  '-c', 'features.shell_tool=false', '-c', 'web_search="disabled"', '-c', 'cli_auth_credentials_store="file"'], {
  cwd: join(home, 'empty-workspace'),
  env: { PATH: process.env.PATH, HOME: home, CODEX_HOME: join(home, '.codex'), TMPDIR: join(root, '.local/tmp'),
    XDG_CONFIG_HOME: join(home, '.config'), XDG_DATA_HOME: join(home, '.data'), LANG: 'en_US.UTF-8' },
  stdio: ['pipe', 'pipe', 'pipe'],
});
child.stderr.resume();
const rpc = new Rpc(child.stdout, child.stdin);
child.on('error', () => rpc.close());
child.on('exit', () => rpc.close());
let answer = '';
const session = new Session(rpc, createTools({ memory }), {
  onText: text => { answer += text; }, onTool: event => console.log('[tool]', JSON.stringify(event)),
});
async function turn(text) {
  memory.discard(); answer = '';
  console.log('[input]', text);
  await session.turn(text);
  console.log('[answer]', answer);
  assert.doesNotMatch(answer, /\/confirm\s+[a-f0-9-]+/i, 'confirmation commands belong to host output, not model text');
  return [...memory.pending.values()][0];
}
try {
  await session.initialize();
  const config = await session.start(join(home, 'empty-workspace'));
  console.log('[session]', JSON.stringify(config));
  assert.equal(await turn('麻薯还剩两个。'), undefined, 'ambiguous shop must not produce a change');
  assert.match(answer, /盒马/); assert.match(answer, /山姆/);
  const wrong = await turn('是山姆那盒。');
  assert.equal(wrong.recordId, sams); assert.equal(wrong.after.quantity, 2);
  const corrected = await turn('不是山姆，是盒马，刚才说错了。');
  assert.equal(corrected.recordId, hema); assert.equal(corrected.after.quantity, 2);
  assert.throws(() => memory.confirm(wrong.id), /expired/);
  memory.confirm(corrected.id);
  assert.equal(memory.records().find(r => r.id === sams).quantity, 18);

  const revision = await turn('以后盒马买的麻薯都放冰箱下层，其他习惯不变。这次只修改习惯，不搬动已有的东西。');
  assert.equal(revision.recordId, habit);
  assert.match(revision.after.text, /6/); assert.match(revision.after.text, /下层/);
  assert.doesNotMatch(revision.after.text, /上层/);
  memory.confirm(revision.id);
  assert.equal(memory.records().length, 3);
  assert.equal(memory.records().find(r => r.id === hema).location, '冰箱上层');

  let repeat = await turn('今天又在盒马买了一盒麻薯，跟平时一样。');
  if (!repeat) repeat = await turn('还是六个，按新习惯放。包装日期还没看清，先留空。');
  assert.equal(repeat.before, null);
  assert.equal(repeat.after.kind, 'batch'); assert.equal(repeat.after.shop, '盒马');
  assert.equal(repeat.after.quantity, 6); assert.equal(repeat.after.expiryDate, null);
  assert.match(repeat.after.location, /下层/);
  memory.confirm(repeat.id);
  console.log('LIVE SCENARIOS PASSED: ambiguity, corrected target, revised habit, repurchase without inherited expiry; Jev disabled');
} finally {
  rpc.close(); child.kill();
  const force = setTimeout(() => child.kill('SIGKILL'), 2000); force.unref();
  child.once('exit', () => clearTimeout(force));
  memory.close();
  await rm(dir, { recursive: true, force: true });
}
