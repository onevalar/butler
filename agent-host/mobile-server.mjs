import { spawn, execFileSync } from 'node:child_process';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { randomBytes } from 'node:crypto';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Rpc } from './rpc.mjs';
import { Session } from './session.mjs';
import { createTools } from './tools.mjs';
import { MemoryStore } from './memory.mjs';
import { mobileAPI } from './mobile-api.mjs';

process.umask(0o077);
const root = fileURLToPath(new URL('.', import.meta.url));
const local = join(root, '.local');
const home = join(local, 'home');
const cwd = join(home, 'empty-workspace');
for (const dir of [cwd, join(home, '.codex'), join(local, 'tmp')]) await mkdir(dir, { recursive: true, mode: 0o700 });
const tokenPath = join(local, 'mobile-token');
try { await writeFile(tokenPath, randomBytes(32).toString('base64url'), { flag: 'wx', mode: 0o600 }); }
catch (error) { if (error.code !== 'EEXIST') throw error; }
const token = (await readFile(tokenPath, 'utf8')).trim();
const env = { PATH: process.env.PATH, HOME: home, CODEX_HOME: join(home, '.codex'), TMPDIR: join(local, 'tmp'),
  XDG_CONFIG_HOME: join(home, '.config'), XDG_DATA_HOME: join(home, '.data'), LANG: 'en_US.UTF-8' };
const binary = join(root, 'node_modules/.bin/codex');
if (execFileSync(binary, ['--version'], { env, encoding: 'utf8' }).trim() !== 'codex-cli 0.157.1') throw new Error('unexpected_codex_version');
const child = spawn(binary, ['app-server', '--listen', 'stdio://', '-c', 'features.shell_tool=false',
  '-c', 'web_search="disabled"', '-c', 'cli_auth_credentials_store="file"'], { env, cwd, stdio: ['pipe', 'pipe', 'pipe'] });
child.stderr.resume();
const rpc = new Rpc(child.stdout, child.stdin);
child.on('error', () => rpc.close()); child.on('exit', () => rpc.close());
// Different file from CLI tests and from the iOS inventory. Jev deliberately disabled.
const memory = new MemoryStore(join(local, 'mobile-fictional.sqlite'));
const session = new Session(rpc, createTools({ memory }));
let api;
async function stop() {
  api?.server.close();
  rpc.close(); child.kill();
  await api?.settled();
  memory.close();
}
try {
  await session.initialize();
  const account = await rpc.request('account/read', { refreshToken: false });
  if (account.account?.type !== 'chatgpt') throw new Error('login_required_run_npm_start_login');
  const config = await session.start(cwd);
  api = mobileAPI({ memory, session, token });
  const port = Number(process.env.PORT ?? 8787);
  api.server.listen(port, '127.0.0.1', () => console.log(`Butler mobile test API ready on loopback port ${port}; ${JSON.stringify(config)}; token file: .local/mobile-token (do not share in chat)`));
  let stopping = false;
  for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => {
    if (!stopping) { stopping = true; void stop(); }
  });
} catch (error) {
  await stop();
  console.error(/^[a-z_]+$/.test(error.message) ? error.message : 'mobile_start_failed');
  process.exitCode = 1;
}
