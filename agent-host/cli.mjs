import { spawn, execFileSync } from 'node:child_process';
import { mkdir, readFile, chmod } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';
import { createInterface } from 'node:readline/promises';
import { Rpc } from './rpc.mjs';
import { Session } from './session.mjs';
import { createTools } from './tools.mjs';
import { MemoryStore } from './memory.mjs';

const root = fileURLToPath(new URL('.', import.meta.url));
const binary = join(root, 'node_modules/.bin/codex');
const local = join(root, '.local');
const home = join(local, 'home');
const cwd = join(home, 'empty-workspace');
const codexHome = join(home, '.codex');
const command = process.argv[2] ?? 'check';
const allowJev = process.argv.includes('--allow-jev');

// Do not give the child Jev/API keys or inherit the user's Codex/AGENTS/MCP config.
function childEnv() {
  return { PATH: process.env.PATH, HOME: home, CODEX_HOME: codexHome,
    TMPDIR: join(local, 'tmp'), XDG_CONFIG_HOME: join(home, '.config'),
    XDG_DATA_HOME: join(home, '.data'), LANG: 'en_US.UTF-8' };
}

async function prepare() {
  process.umask(0o077);
  for (const dir of [cwd, codexHome, join(local, 'tmp')]) await mkdir(dir, { recursive: true, mode: 0o700 });
  await chmod(local, 0o700);
  const version = execFileSync(binary, ['--version'], { env: childEnv(), cwd, encoding: 'utf8' }).trim();
  if (version !== 'codex-cli 0.157.1') throw new Error('unexpected_codex_version');
  execFileSync(binary, ['app-server', 'generate-json-schema', '--experimental', '--out', join(local, 'schema')],
    { env: childEnv(), cwd, stdio: 'ignore' });
  const schema = JSON.parse(await readFile(join(local, 'schema/v2/ThreadStartParams.json'), 'utf8'));
  if (!schema.properties?.environments || !schema.properties?.dynamicTools) throw new Error('required_protocol_not_supported');
  console.log(`${version}; required experimental protocol fields: OK`);
}

function waitLogin(rpc) {
  let cleanup;
  const promise = new Promise(resolve => {
    const handler = ({ method, params }) => {
      if (method === 'account/login/completed') { cleanup(); resolve(params?.success === true); }
    };
    const closed = () => { cleanup(); resolve(false); };
    const timer = setTimeout(closed, 180_000);
    cleanup = () => { clearTimeout(timer); rpc.off('notification', handler); rpc.off('closed', closed); };
    rpc.on('notification', handler);
    rpc.on('closed', closed);
  });
  return { promise, cleanup: () => cleanup() };
}

async function main() {
  if (!['check', 'login', 'chat', 'logout'].includes(command)
    || process.argv.slice(3).some(arg => arg !== '--allow-jev')) throw new Error('usage: npm start -- check|login|chat|logout [--allow-jev]');
  await prepare();
  const memory = command === 'chat' ? new MemoryStore(join(local, 'fictional-memory.sqlite')) : null;
  const child = spawn(binary, ['app-server', '--listen', 'stdio://',
    '-c', 'features.shell_tool=false', '-c', 'web_search="disabled"',
    '-c', 'cli_auth_credentials_store="file"'], { env: childEnv(), cwd, stdio: ['pipe', 'pipe', 'pipe'] });
  // Avoid printing raw provider diagnostics, which can include private material.
  child.stderr.resume();
  const rpc = new Rpc(child.stdout, child.stdin);
  child.on('error', () => rpc.close());
  child.on('exit', () => rpc.close());
  rpc.on('closed', () => child.kill());
  const session = new Session(rpc, createTools({ memory, apiKey: process.env.TYPESAFE_API_KEY, allowJev }), {
    onText: text => process.stdout.write(text),
    onTool: event => console.log(`\n[tool] ${JSON.stringify(event)}`),
  });
  const interrupt = () => { if (session.active) void session.cancel(); else rpc.close(); };
  process.on('SIGINT', interrupt);
  let terminal;
  try {
    await session.initialize();
    const account = await rpc.request('account/read', { refreshToken: false });
    if (command === 'check') {
      console.log(`App Server handshake: OK; authentication: ${account.account?.type ?? 'signed_out'}`);
      console.log('No model turn or Jev request was made.');
      return;
    }
    if (command === 'logout') {
      await rpc.request('account/logout');
      console.log('Prototype account signed out.');
      return;
    }
    if (command === 'login') {
      const waiting = waitLogin(rpc);
      try {
        const result = await rpc.request('account/login/start', { type: 'chatgptDeviceCode' });
        console.log('在官方页面完成授权；不要把设备码、密码或凭证发给别人。');
        console.log(result.verificationUrl);
        console.log(`设备码：${result.userCode}`);
        if (!await waiting.promise) throw new Error('login_failed_or_timed_out');
        console.log('Login completed. No model turn was sent.');
      } finally { waiting.cleanup(); }
      return;
    }
    if (account.account?.type !== 'chatgpt') throw new Error('请先运行 npm start -- login；原型只接受订阅登录，不自动切换 API。');
    await rpc.request('account/rateLimits/read');
    const configuration = await session.start(cwd);
    console.log(`[session] ${JSON.stringify(configuration)}`);
    console.log('仅虚构资料。测试记忆保存在 agent-host/.local/fictional-memory.sqlite，与手机库存无关。');
    console.log('/confirm 预览ID 确认保存（含所示日期）；/cancel 丢弃；/records 查看；/history 历史；/exit 退出。');
    console.log(allowJev ? 'Jev 已启用，每次进程最多 5 次调用（失败也计数），可能计费。' : 'Jev 默认不发请求；需要授权后以 --allow-jev 启用。');
    terminal = createInterface({ input: process.stdin, output: process.stdout });
    terminal.on('SIGINT', interrupt);
    for await (const line of terminal) {
      if (line.trim() === '/exit' || rpc.closed) break;
      if (!line.trim()) continue;
      try {
        const input = line.trim();
        if (input.startsWith('/confirm ')) {
          console.log(`[saved] ${JSON.stringify(memory.confirm(input.slice(9).trim()))}`);
          continue;
        }
        if (input === '/cancel') { memory.discard(); console.log('已丢弃未保存预览。'); continue; }
        if (input === '/records') { console.log(JSON.stringify(memory.records(), null, 2)); continue; }
        if (input === '/history') { console.log(JSON.stringify(memory.history(), null, 2)); continue; }
        if (input.startsWith('/')) { console.log('未知宿主命令。'); continue; }
        memory.discard();
        await session.turn(line);
        console.log('\n[turn completed]');
        for (const proposal of memory.pending.values()) {
          console.log(`[preview] ${JSON.stringify(proposal)}`);
          console.log(`尚未保存。请核对对象、数量和具体日期；确认请输入 /confirm ${proposal.id}`);
        }
      }
      catch (error) { memory.discard(); console.log(`\n[未完成] ${error.message}`); }
      if (rpc.closed) break;
    }
  } finally {
    terminal?.close();
    memory?.close();
    process.off('SIGINT', interrupt);
    rpc.close();
    child.kill();
    const force = setTimeout(() => child.kill('SIGKILL'), 2000);
    force.unref();
    child.once('exit', () => clearTimeout(force));
  }
}

main().catch(error => {
  // Deliberately omit error stacks and child process stdout/stderr.
  console.error(error.code ? `启动失败：${error.code}` : error.message);
  process.exitCode = 1;
});
