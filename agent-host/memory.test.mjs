import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { MemoryStore } from './memory.mjs';
import { createTools } from './tools.mjs';

const purchase = { action: 'purchase', subject: '麻薯', shop: '盒马', quantity: 6, unit: '个', location: '冰箱上层', expiryDate: '2026-10-02' };
const save = (store, args, text = '虚构资料：盒马买了6个麻薯，2026-10-02到期') => {
  const draft = store.propose(args, text);
  return store.confirm(draft.proposal.id);
};
function fixture(t) {
  const dir = mkdtempSync(join(tmpdir(), 'butler-memory-'));
  const path = join(dir, 'test.sqlite');
  const store = new MemoryStore(path);
  t.after(() => { store.close(); rmSync(dir, { recursive: true, force: true }); });
  return { store, path };
}

test('proposal is not a write; confirmed notes and batches survive a separate process', t => {
  const { store, path } = fixture(t);
  const draft = store.propose(purchase, '原始话语');
  assert.deepEqual(store.records(), []);
  assert.deepEqual(store.history(), []);
  // Mutating a tool result must not alter the approved proposal.
  draft.proposal.after.quantity = 500;
  const result = store.confirm(draft.proposal.id);
  assert.equal(result.after.quantity, 6);
  save(store, { action: 'remember', subject: '麻薯', shop: '盒马', text: '习惯放冰箱上层' });
  save(store, { ...purchase, expiryDate: null });
  const output = execFileSync(process.execPath, ['--input-type=module', '-e',
    `import {MemoryStore} from ${JSON.stringify(new URL('./memory.mjs', import.meta.url).href)};
     const m=new MemoryStore(process.argv[1]);console.log(JSON.stringify(m.records()));m.close();`, path], { encoding: 'utf8' });
  const records = JSON.parse(output);
  assert.equal(records.length, 3);
  assert.equal(records[0].quantity, 6);
  assert.equal(records[0].expiryDate, '2026-10-02');
  assert.equal(records[1].kind, 'note');
  assert.equal(records[1].quantity, undefined);
  assert.equal(records[2].expiryDate, null); // No inheritance from old batch.
  assert.deepEqual(store.confirm(draft.proposal.id), result);
  assert.equal(store.history().length, 3); // Duplicate confirmation is not another event.
  assert.equal(store.history().at(-1).sourceText, '原始话语');
});

test('remaining quantity is absolute; undo restores exactly without changing the other shop', t => {
  const { store } = fixture(t);
  save(store, { ...purchase, shop: '山姆', quantity: 18 });
  const hema = save(store, purchase);
  save(store, { action: 'set_quantity', recordId: hema.recordId, revision: 1, quantity: 2 }, '还剩两个');
  assert.deepEqual(store.records().map(r => r.quantity), [18, 2]);
  save(store, { action: 'undo_latest' }, '刚才说错了，撤销');
  assert.deepEqual(store.records().map(r => r.quantity), [18, 6]);
  assert.equal(store.records()[1].revision, 3);
  assert.equal(store.history()[0].before.quantity, 2);
  assert.equal(store.history()[0].after.quantity, 6);
});

test('correction and cancellation expire previous previews; stale revisions cannot write', t => {
  const { store, path } = fixture(t);
  const hema = save(store, purchase);
  const sams = save(store, { ...purchase, shop: '山姆', quantity: 18 });
  const old = store.propose({ action: 'set_quantity', recordId: sams.recordId, revision: 1, quantity: 2 }, '山姆剩2个');
  const corrected = store.propose({ action: 'set_quantity', recordId: hema.recordId, revision: 1, quantity: 2 }, '不是山姆，是盒马');
  assert.throws(() => store.confirm(old.proposal.id), /expired/);
  const other = new MemoryStore(path);
  try { save(other, { action: 'set_quantity', recordId: hema.recordId, revision: 1, quantity: 5 }); }
  finally { other.close(); }
  assert.throws(() => store.confirm(corrected.proposal.id), /changed/);
  assert.deepEqual(store.records().map(r => r.quantity), [5, 18]);
  store.discard();
  assert.throws(() => store.confirm(corrected.proposal.id), /expired/);
  assert.throws(() => store.propose({ action: 'set_quantity', recordId: hema.recordId, revision: 1, quantity: 4 }, '旧版本'), /changed/);
});

test('undo preview refuses changed history, and undoing creation hides rather than reuses its revision', t => {
  const { store, path } = fixture(t);
  const first = save(store, purchase);
  const undo = store.propose({ action: 'undo_latest' }, '撤销');
  const other = new MemoryStore(path);
  try { save(other, { ...purchase, shop: '山姆' }); } finally { other.close(); }
  assert.throws(() => store.confirm(undo.proposal.id), /history_changed/);
  save(store, { action: 'undo_latest' });
  assert.deepEqual(store.records().map(r => r.id), [first.recordId]);
});

test('invalid dates, quantities, unknown records and note quantity edits are rejected', t => {
  const { store } = fixture(t);
  for (const expiryDate of ['2026-02-30', '周五', '2026-13-01', '2026-2-03']) {
    assert.throws(() => store.propose({ ...purchase, expiryDate }, '测试'), /invalid/);
  }
  for (const quantity of [-1, 1.5, '2', Number.MAX_SAFE_INTEGER + 1]) {
    assert.throws(() => store.propose({ ...purchase, quantity }, '测试'), /invalid/);
  }
  assert.throws(() => store.propose({ ...purchase, extra: true }, '测试'), /invalid/);
  const note = save(store, { action: 'remember', subject: '衣服', shop: '', text: '蓝色外套在玄关' });
  assert.throws(() => store.propose({ action: 'set_quantity', recordId: note.recordId, revision: 1, quantity: 2 }, '测试'), /not_a_purchase/);
  assert.throws(() => store.propose({ action: 'set_quantity', recordId: 'missing', revision: 1, quantity: 2 }, '测试'), /missing/);
  save(store, { ...purchase, quantity: 0 });
  assert.equal(store.records()[1].quantity, 0);
});

test('transaction failure rolls back record, event and receipt together', t => {
  const { store } = fixture(t);
  const proposal = store.propose(purchase, '测试');
  store.db.exec("CREATE TRIGGER fail_event BEFORE INSERT ON events BEGIN SELECT RAISE(ABORT, 'simulated failure'); END;");
  assert.throws(() => store.confirm(proposal.proposal.id), /simulated failure/);
  assert.deepEqual(store.records(), []);
  assert.deepEqual(store.history(), []);
  store.db.exec('DROP TRIGGER fail_event');
  assert.equal(store.confirm(proposal.proposal.id).saved, true);
  assert.equal(store.history().length, 1);
});

test('model tools use persistent records, preserve original input and cannot confirm', async t => {
  const { store } = fixture(t);
  const tools = createTools({ memory: store });
  const result = await tools('propose_memory_change', purchase, undefined, { text: '用户的原话' });
  assert.equal(result.saved, false);
  assert.deepEqual((await tools('search_memory', { query: '麻薯' })).records, []);
  await assert.rejects(tools('confirm', { id: result.proposal.id }), /unknown_tool/);
  store.confirm(result.proposal.id);
  assert.equal((await tools('search_memory', { query: '盒马' })).records[0].quantity, 6);
  assert.equal((await tools('memory_history', {})).events[0].sourceText, '用户的原话');
  await assert.rejects(tools('propose_memory_change', purchase, AbortSignal.abort(), { text: '已取消' }));
  assert.equal(store.pending.size, 0);
});

test('habit correction replaces one note, preserves batches and other shops, and can be undone', async t => {
  const { store, path } = fixture(t);
  const hema = save(store, { action: 'remember', subject: '麻薯', shop: '盒马', text: '每盒6个，习惯放冰箱上层' });
  save(store, { action: 'remember', subject: '麻薯', shop: '山姆', text: '每盒18个，放冷冻室' });
  const batch = save(store, purchase);
  const tools = createTools({ memory: store });
  const draft = await tools('propose_memory_change', {
    action: 'revise_note', recordId: hema.recordId, revision: 1, text: '每盒6个，以后放冰箱下层',
  }, undefined, { text: '以后盒马麻薯放下面' });
  assert.match(store.records()[0].text, /上层/);
  store.confirm(draft.proposal.id);
  const reopened = new MemoryStore(path);
  try {
    assert.equal(reopened.records().length, 3);
    assert.equal(reopened.records()[0].id, hema.recordId);
    assert.equal(reopened.records()[0].text, '每盒6个，以后放冰箱下层');
    assert.equal(reopened.records()[1].text, '每盒18个，放冷冻室');
    assert.equal(reopened.records()[2].location, '冰箱上层');
    assert.equal((await createTools({ memory: reopened })('search_memory', { query: '上层' })).records.length, 1);
  } finally { reopened.close(); }
  assert.throws(() => store.propose({ action: 'revise_note', recordId: hema.recordId, revision: 1, text: '过期更正' }, '旧请求'), /changed/);
  assert.throws(() => store.propose({ action: 'revise_note', recordId: batch.recordId, revision: 1, text: '误改批次' }, '错误类型'), /not_a_memory_note/);
  save(store, { action: 'undo_latest' }, '撤销习惯更正');
  assert.equal(store.records()[0].text, '每盒6个，习惯放冰箱上层');
  assert.equal(store.history()[1].sourceText, '以后盒马麻薯放下面');
});

test('failed correction invalidates old preview; confirmation receipt survives lost response and restart', t => {
  const { store, path } = fixture(t);
  const old = store.propose(purchase, '旧预览');
  assert.throws(() => store.propose({ action: 'revise_note', recordId: 'missing', revision: 1, text: '更正' }, '改口'), /missing/);
  assert.throws(() => store.confirm(old.proposal.id), /expired/);
  const draft = store.propose(purchase, '新预览');
  const committed = store.confirm(draft.proposal.id); // Pretend the caller lost this response.
  const reopened = new MemoryStore(path);
  try {
    assert.deepEqual(reopened.confirm(draft.proposal.id), committed);
    assert.equal(reopened.records().length, 1);
    assert.equal(reopened.history().length, 1);
  } finally { reopened.close(); }
});
