'use strict';
// Trusted, dependency-free controls only. Never require candidate packages here.
const fs = require('node:fs');
const net = require('node:net');
const crypto = require('node:crypto');
const { fork } = require('node:child_process');
const assert = require('node:assert/strict');
const path = require('node:path');
const LIMIT = 1024 * 1024;
const mode = process.argv[2];
const input = JSON.parse(process.argv[3] || '{}');
const cleanEnv = { PATH: '/usr/local/bin:/usr/bin:/bin', TMPDIR: '/tmp' };

function emit(value) {
  const bytes = JSON.stringify(value);
  assert(Buffer.byteLength(bytes) <= LIMIT, 'control report oversized');
  process.stdout.write(`${bytes}\n`);
}

function namespace() {
  const stat = fs.statSync('/proc/self/ns/net', { bigint: true });
  return [String(stat.dev), String(stat.ino)];
}

function descriptors(extraFD = false) {
  const entries = [];
  for (const name of fs.readdirSync('/proc/self/fd')) {
    let target;
    try { target = fs.readlinkSync(`/proc/self/fd/${name}`); }
    catch (error) { if (error.code === 'ENOENT') continue; throw error; }
    const fd = Number(name);
    const runtime = /^(pipe:\[\d+\]|anon_inode:\[(eventpoll|eventfd)\]|\/dev\/null)$/.test(target);
    const stdioOrIPC = /^socket:\[\d+\]$/.test(target) && (fd <= 2 || (extraFD && fd === 4));
    const owned = extraFD && fd === 3 && target === '/tmp/d1-positive-fd';
    assert(runtime || stdioOrIPC || owned, `unexpected open descriptor ${fd}: ${target}`);
    entries.push({ fd, target });
  }
  assert(entries.some((entry) => entry.fd === 0), 'stdin evidence missing');
  return entries;
}

function denied(operation, codes) {
  try { operation(); } catch (error) {
    assert(codes.includes(error.code), `unexpected denial ${error.code}`);
    return error.code;
  }
  throw new Error('negative control unexpectedly succeeded');
}

function connectDenied(host, port) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection({ host, port });
    let finished = false;
    const finish = (error, code) => {
      if (finished) return;
      finished = true;
      socket.once('close', () => error ? reject(error) : resolve({ host, port, error: code }));
      socket.destroy();
    };
    socket.setTimeout(1500, () => finish(new Error('network control timeout: indeterminate')));
    socket.once('connect', () => finish(new Error('network negative control connected')));
    socket.once('error', (error) => {
      const allowed = ['ENETUNREACH', 'EHOSTUNREACH', 'ECONNREFUSED', 'EADDRNOTAVAIL', 'EACCES', 'EPERM'];
      finish(allowed.includes(error.code) ? null : error, error.code);
    });
  });
}

async function controls(child) {
  assert(process.getuid() === 10001 && process.getgid() === 10001, 'wrong payload identity');
  const status = fs.readFileSync('/proc/self/status', 'utf8');
  for (const key of ['CapInh', 'CapPrm', 'CapEff', 'CapBnd', 'CapAmb'])
    assert(new RegExp(`^${key}:\\s+0+$`, 'm').test(status), `${key} not empty`);
  assert(/^NoNewPrivs:\s+1$/m.test(status), 'no-new-privileges absent');
  assert(/^Seccomp:\s+2$/m.test(status), 'default seccomp inactive');
  assert.deepEqual(Object.keys(process.env).sort(), child
    ? Object.keys(cleanEnv).sort() : ['CI', 'NODE_ENV', 'PATH', 'TMPDIR'].sort());
  const privateRead = denied(() => fs.readFileSync(input.privatePath), ['ENOENT', 'EACCES']);
  const sourceWrite = denied(() => {
    const fd = fs.openSync('/work/sdk/package.json', 'r+');
    fs.closeSync(fd);
  }, ['EROFS', 'EACCES']);
  const dependencyWrite = denied(() => {
    const fd = fs.openSync('/work/sdk/node_modules/vitest/package.json', 'r+');
    fs.closeSync(fd);
  }, ['EROFS', 'EACCES']);
  const wrapperWrite = denied(() => {
    const fd = fs.openSync('/cache/config/vitest.config.mjs', 'r+');
    fs.closeSync(fd);
  }, ['EROFS', 'EACCES']);
  const scratch = `/tmp/d1-scratch-${child ? 'child' : 'parent'}`;
  fs.writeFileSync(scratch, input.nonce, { flag: 'wx' });
  assert.equal(fs.readFileSync(scratch, 'utf8'), input.nonce);
  fs.unlinkSync(scratch);
  const network = [];
  for (const listener of input.listeners)
    network.push(await connectDenied(listener.host, listener.port));
  assert.equal(network.length, 2);
  const result = {
    namespace: namespace(), pid: process.pid, privateRead, sourceWrite,
    dependencyWrite, wrapperWrite, scratch: true, network,
    descriptors: descriptors(child), builtinLoad: typeof crypto.createHash === 'function',
  };
  if (child) {
    assert.equal(fs.readFileSync(3, 'utf8'), input.nonce);
    result.fdPositive = true;
    assert(typeof process.send === 'function');
    process.send({ nonce: input.nonce, result }, () => process.disconnect());
    return;
  }
  const fd = fs.openSync('/tmp/d1-positive-fd', 'wx+');
  fs.writeSync(fd, input.nonce, 0, 'utf8');
  try {
    result.child = await new Promise((resolve, reject) => {
      const childProcess = fork(__filename, ['controls-child', JSON.stringify(input)], {
        execPath: '/usr/local/bin/node', execArgv: [], env: cleanEnv,
        stdio: ['ignore', 'pipe', 'pipe', fd, 'ipc'],
      });
      let response;
      let bytes = 0;
      let invalid = false;
      const timer = setTimeout(() => {
        invalid = true;
        // ChildProcess retains unreaped child identity; never signal after exit.
        if (childProcess.exitCode === null && childProcess.signalCode === null) childProcess.kill('SIGKILL');
      }, 8000);
      childProcess.on('message', (message) => {
        if (response) invalid = true;
        response = message;
      });
      for (const stream of [childProcess.stdout, childProcess.stderr]) stream.on('data', (chunk) => {
        bytes += chunk.length;
        invalid = true; // A successful child must be silent except controlled IPC.
        if (bytes > 65536 && childProcess.exitCode === null && childProcess.signalCode === null)
          childProcess.kill('SIGKILL');
      });
      childProcess.once('error', reject);
      childProcess.once('close', (code, signal) => {
        clearTimeout(timer);
        if (invalid || code !== 0 || signal || response?.nonce !== input.nonce)
          reject(new Error('child/IPC/FD control failed'));
        else resolve({ ...response.result, code, signal, ipcPositive: true });
      });
    });
  } finally {
    fs.closeSync(fd);
    fs.unlinkSync('/tmp/d1-positive-fd');
  }
  emit(result);
}

async function interruption() {
  const child = fork(__filename, ['interrupt-child'], {
    execPath: '/usr/local/bin/node', execArgv: [], env: cleanEnv,
    stdio: ['ignore', 'ignore', 'ignore', 'ipc'],
  });
  child.once('message', (message) => {
    assert.equal(message.pid, child.pid);
    fs.writeFileSync('/tmp/interruption.json', JSON.stringify({
      parent: process.pid, child: child.pid, namespace: namespace(),
    }), { flag: 'wx' });
  });
  child.once('error', (error) => { throw error; });
  setInterval(() => {}, 1000);
}

function readReport(name) {
  const filename = `/reports/${name}`;
  const fd = fs.openSync(filename, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  try {
    const stat = fs.fstatSync(fd);
    assert(stat.isFile() && stat.size > 0 && stat.size <= LIMIT, 'invalid report size/type');
    return JSON.parse(fs.readFileSync(fd, 'utf8'));
  } finally { fs.closeSync(fd); }
}

function scratchInventory() {
  const files = [];
  function visit(directory) {
    for (const name of fs.readdirSync(directory).sort()) {
      const filename = path.join(directory, name);
      const stat = fs.lstatSync(filename);
      assert(!stat.isSymbolicLink(), 'scratch symlink');
      if (stat.isDirectory()) visit(filename);
      else {
        assert(stat.isFile(), 'scratch special file');
        files.push({ path: filename, size: stat.size });
      }
      assert(files.length < 4096, 'scratch inventory excessive');
    }
  }
  for (const directory of ['/tmp', '/cache', '/reports']) visit(directory);
  return files;
}

async function main() {
  if (mode === 'namespace') return emit({ namespace: namespace(), uid: process.getuid(), gid: process.getgid() });
  if (mode === 'controls' || mode === 'controls-child') return controls(mode.endsWith('-child'));
  if (mode === 'interrupt') return interruption();
  if (mode === 'interrupt-child') {
    process.send({ pid: process.pid });
    setInterval(() => {}, 1000);
    return;
  }
  if (mode === 'interrupt-state') {
    // Readiness waiting is bounded; missing evidence remains failure, never skip.
    for (let attempt = 0; attempt < 40; attempt++) {
      if (fs.existsSync('/tmp/interruption.json'))
        return emit(JSON.parse(fs.readFileSync('/tmp/interruption.json', 'utf8')));
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    throw new Error('interruption child never ready');
  }
  if (mode === 'reports') return emit({
    harness: readReport('harness.json'), vitest: readReport('vitest.json'), scratch: scratchInventory(),
  });
  if (mode === 'version') return emit({ node: process.version, arch: process.arch, platform: process.platform });
  throw new Error('unknown trusted control operation');
}

main().catch((error) => {
  process.stderr.write(`D1_CONTROL_FAILURE: ${error.stack}\n`);
  process.exitCode = 2;
});
