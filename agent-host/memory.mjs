import { DatabaseSync } from 'node:sqlite';
import { randomUUID } from 'node:crypto';

const text = value => typeof value === 'string' && value.trim().length > 0 && value.length <= 2000;
const quantity = value => Number.isSafeInteger(value) && value >= 0;
const date = value => value === null || (typeof value === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(value)
  && Number.isFinite(Date.parse(value)) && new Date(value).toISOString().slice(0, 10) === value);
const fields = (value, keys) => Object.keys(value).sort().join(',') === [...keys].sort().join(',');

// Disposable fictional data only. The model can propose changes, never commit them.
export class MemoryStore {
  constructor(path) {
    this.db = new DatabaseSync(path);
    this.db.exec(`PRAGMA busy_timeout = 3000;
      CREATE TABLE IF NOT EXISTS records (id TEXT PRIMARY KEY, revision INTEGER NOT NULL, body TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS events (id TEXT PRIMARY KEY, record_id TEXT NOT NULL,
        before_body TEXT, after_body TEXT, source TEXT NOT NULL, created_at TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS confirmations (id TEXT PRIMARY KEY, result TEXT NOT NULL);`);
    this.pending = new Map();
  }

  close() { this.db.close(); }
  discard() { this.pending.clear(); }
  records() {
    return this.db.prepare('SELECT id, revision, body FROM records WHERE body != \'null\' ORDER BY rowid')
      .all().map(row => ({ id: row.id, revision: row.revision, ...JSON.parse(row.body), source: 'fictional_persistent' }));
  }
  history() {
    return this.db.prepare('SELECT * FROM events ORDER BY rowid DESC LIMIT 20').all()
      .map(row => ({ id: row.id, recordId: row.record_id, before: JSON.parse(row.before_body),
        after: JSON.parse(row.after_body), sourceText: row.source, createdAt: row.created_at }));
  }

  propose(args, sourceText) {
    // Even a rejected correction invalidates the old preview.
    this.discard();
    if (!text(sourceText) || !args || typeof args !== 'object' || Array.isArray(args)) throw new Error('invalid_arguments');
    let recordId, before = null, after, revision = 0, undoEvent = null;
    if (args.action === 'remember' || args.action === 'purchase') {
      const keys = args.action === 'remember' ? ['action', 'subject', 'shop', 'text']
        : ['action', 'subject', 'shop', 'quantity', 'unit', 'location', 'expiryDate'];
      if (!fields(args, keys) || !text(args.subject) || typeof args.shop !== 'string' || args.shop.length > 200
        || (args.action === 'remember' && !text(args.text))
        || (args.action === 'purchase' && (!quantity(args.quantity) || !text(args.unit)
          || typeof args.location !== 'string' || args.location.length > 200 || !date(args.expiryDate)))) {
        throw new Error('invalid_arguments');
      }
      recordId = randomUUID();
      const { action, ...body } = args;
      after = { kind: action === 'remember' ? 'note' : 'batch', ...body };
    } else if (args.action === 'set_quantity' || args.action === 'revise_note') {
      const valueKey = args.action === 'set_quantity' ? 'quantity' : 'text';
      if (!fields(args, ['action', 'recordId', 'revision', valueKey]) || !text(args.recordId)
        || !Number.isSafeInteger(args.revision) || args.revision < 1
        || (valueKey === 'quantity' ? !quantity(args.quantity) : !text(args.text))) throw new Error('invalid_arguments');
      const row = this.db.prepare('SELECT * FROM records WHERE id = ?').get(args.recordId);
      if (!row || row.revision !== args.revision) throw new Error('record_missing_or_changed');
      before = JSON.parse(row.body);
      if (valueKey === 'quantity' && before?.kind !== 'batch') throw new Error('not_a_purchase_batch');
      if (valueKey === 'text' && before?.kind !== 'note') throw new Error('not_a_memory_note');
      recordId = row.id; revision = row.revision;
      after = { ...before, [valueKey]: args[valueKey] };
    } else if (args.action === 'undo_latest') {
      if (!fields(args, ['action'])) throw new Error('invalid_arguments');
      const event = this.db.prepare('SELECT * FROM events ORDER BY rowid DESC LIMIT 1').get();
      if (!event) throw new Error('nothing_to_undo');
      const row = this.db.prepare('SELECT * FROM records WHERE id = ?').get(event.record_id);
      recordId = row.id; revision = row.revision; before = JSON.parse(row.body);
      after = JSON.parse(event.before_body); undoEvent = event.id;
    } else throw new Error('invalid_arguments');
    const id = randomUUID();
    const proposal = { id, recordId, revision, before, after, sourceText, undoEvent };
    this.pending.set(id, structuredClone(proposal));
    return { source: 'pending_confirmation', proposal, saved: false };
  }

  confirm(id) {
    this.db.exec('BEGIN IMMEDIATE');
    try {
      const previous = this.db.prepare('SELECT result FROM confirmations WHERE id = ?').get(id);
      if (previous) { this.db.exec('COMMIT'); return JSON.parse(previous.result); }
      const draft = this.pending.get(id);
      if (!draft) throw new Error('confirmation_missing_or_expired');
      const row = this.db.prepare('SELECT revision FROM records WHERE id = ?').get(draft.recordId);
      if ((row?.revision ?? 0) !== draft.revision) throw new Error('record_changed_review_again');
      if (draft.undoEvent && this.db.prepare('SELECT id FROM events ORDER BY rowid DESC LIMIT 1').get()?.id !== draft.undoEvent) {
        throw new Error('history_changed_review_again');
      }
      this.db.prepare(`INSERT INTO records VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE
        SET revision = excluded.revision, body = excluded.body`).run(draft.recordId, draft.revision + 1, JSON.stringify(draft.after));
      const eventId = randomUUID();
      this.db.prepare('INSERT INTO events VALUES (?, ?, ?, ?, ?, ?)').run(eventId, draft.recordId,
        JSON.stringify(draft.before), JSON.stringify(draft.after), draft.sourceText, new Date().toISOString());
      const result = { source: 'fictional_persistent', saved: true, recordId: draft.recordId, eventId, after: draft.after };
      this.db.prepare('INSERT INTO confirmations VALUES (?, ?)').run(id, JSON.stringify(result));
      this.db.exec('COMMIT');
      this.pending.delete(id);
      return result;
    } catch (error) { this.db.exec('ROLLBACK'); throw error; }
  }
}
