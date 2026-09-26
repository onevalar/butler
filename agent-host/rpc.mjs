import { EventEmitter } from 'node:events';

// JSONL bidirectional RPC. No provider payloads are included in transport errors.
export class Rpc extends EventEmitter {
  constructor(input, output, { timeoutMs = 15_000, maxFrameBytes = 2_000_000 } = {}) {
    super();
    this.output = output;
    this.timeoutMs = timeoutMs;
    this.maxFrameBytes = maxFrameBytes;
    this.pending = new Map();
    this.nextId = 1;
    this.buffer = '';
    input.setEncoding('utf8');
    input.on('data', chunk => this.receive(chunk));
    input.on('end', () => this.close());
    input.on('error', () => this.close());
    output.on('error', () => this.close());
  }

  send(message) {
    if (this.closed) throw new Error('connection_closed');
    this.output.write(`${JSON.stringify(message)}\n`);
  }

  request(method, params = {}) {
    if (this.closed) return Promise.reject(new Error('connection_closed'));
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`request_timeout:${method}`));
        // The operation may still be running. Never replay automatically.
        this.close();
      }, this.timeoutMs);
      this.pending.set(id, { resolve, reject, timer });
      try { this.send({ id, method, params }); }
      catch { this.close(); }
    });
  }

  receive(chunk) {
    if (this.closed) return;
    this.buffer += chunk;
    let end;
    while ((end = this.buffer.indexOf('\n')) >= 0) {
      const line = this.buffer.slice(0, end);
      this.buffer = this.buffer.slice(end + 1);
      if (!line.trim()) continue;
      if (Buffer.byteLength(line) > this.maxFrameBytes) return this.close();
      let message;
      try { message = JSON.parse(line); }
      catch { return this.close(); }
      if (!message || typeof message !== 'object' || Array.isArray(message)) return this.close();
      if (typeof message.method === 'string') {
        this.emit(Object.hasOwn(message, 'id') ? 'request' : 'notification', message);
      } else if (Object.hasOwn(message, 'id')) {
        const pending = this.pending.get(message.id);
        if (!pending) continue;
        clearTimeout(pending.timer);
        this.pending.delete(message.id);
        if (message.error) pending.reject(new Error(`rpc_error:${message.error.code ?? 'unknown'}`));
        else if (Object.hasOwn(message, 'result')) pending.resolve(message.result);
        else pending.reject(new Error('invalid_response'));
      } else return this.close();
    }
    if (Buffer.byteLength(this.buffer) > this.maxFrameBytes) this.close();
  }

  close() {
    if (this.closed) return;
    this.closed = true;
    for (const { reject, timer } of this.pending.values()) {
      clearTimeout(timer);
      reject(new Error('connection_closed'));
    }
    this.pending.clear();
    this.emit('closed');
  }
}
