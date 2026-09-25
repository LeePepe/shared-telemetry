import Ajv from 'ajv';
import {mkdtemp, readFile, writeFile, cp, rm, realpath} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';

const sdk = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const readJSON = async file => JSON.parse(await readFile(file, 'utf8'));

export function checkLockfile(lockfile) {
  for (const entry of Object.values(lockfile.packages)) {
    if (entry.resolved && !entry.resolved.startsWith('https://registry.npmjs.org/'))
      throw new Error('WEB_AI_REGISTRY: distribution lockfile must use the public npm registry');
  }
}

export async function checkContract(packageRoot) {
  const ai = await realpath(path.join(packageRoot, 'ai'));
  const registry = await readJSON(path.join(ai, 'registry.json'));
  const manifest = await readJSON(path.join(packageRoot, 'package.json'));
  const schema = await readJSON(path.join(ai, 'registry.schema.json'));
  const validate = new Ajv({strict: true}).compile(schema);
  if (!validate(registry)) throw new Error(`WEB_AI_SCHEMA: ${JSON.stringify(validate.errors)}`);
  if (registry.version !== manifest.version || registry.package !== manifest.name)
    throw new Error('WEB_AI_VERSION: installed package identity/version mismatch');
  async function resolve(target) {
    const candidate = path.resolve(ai, target.split('#')[0]);
    const relative = path.relative(ai, candidate);
    if (relative.startsWith('..') || path.isAbsolute(relative)) throw new Error('WEB_AI_PATH: escaping link');
    let actual;
    try { actual = await realpath(candidate); } catch { throw new Error(`WEB_AI_DOCUMENT: ${target}`); }
    if (!actual.startsWith(`${ai}${path.sep}`)) throw new Error('WEB_AI_PATH: escaping symlink');
    return readFile(actual, 'utf8');
  }
  for (const document of Object.values(registry.documents)) {
    const content = await resolve(document);
    for (const [, target] of content.matchAll(/\[[^\]]*\]\(([^\s)]+)\)/g)) {
      if (!target.includes('://') && !target.startsWith('#')) await resolve(target);
    }
  }
  await resolve(registry.example);
  const exports = await import(pathToFileURL(path.join(packageRoot, 'dist/index.js')));
  if (JSON.stringify(Object.keys(exports).sort()) !== JSON.stringify([...registry.runtimeExports].sort()))
    throw new Error('WEB_AI_API: runtime export registry drift');
  const declarations = await readFile(path.join(packageRoot, 'dist/index.d.ts'), 'utf8');
  for (const name of registry.typeExports) {
    if (!new RegExp(`\\b${name}\\b`).test(declarations)) throw new Error(`WEB_AI_API: missing type ${name}`);
  }
  return registry;
}

function run(command, args, cwd) {
  execFileSync(command, args, {cwd, stdio: 'inherit'});
}

async function main() {
  checkLockfile(await readJSON(path.join(sdk, 'package-lock.json')));
  const scratch = await mkdtemp(path.join(tmpdir(), 'loki-web-consumer-'));
  try {
    const packed = JSON.parse(execFileSync('npm', ['pack', '--json', '--pack-destination', scratch], {cwd: sdk, encoding: 'utf8'}));
    if (packed.length !== 1) throw new Error('WEB_AI_ARTIFACT: expected one tarball');
    const artifact = path.join(scratch, packed[0].filename);
    await writeFile(path.join(scratch, 'package.json'), JSON.stringify({name: 'synthetic-consumer', private: true, type: 'module'}));
    run('npm', ['install', '--ignore-scripts', '--no-audit', '--no-fund', artifact], scratch);
    const installed = path.join(scratch, 'node_modules/@leepepe/loki-web');
    const registry = await checkContract(installed);
    await cp(path.join(installed, 'ai', registry.example), path.join(scratch, 'consumer.ts'));
    run(process.execPath, [path.join(sdk, 'node_modules/typescript/bin/tsc'), '--strict', '--target', 'ES2022',
      '--module', 'NodeNext', '--moduleResolution', 'NodeNext', '--lib', 'ES2022,DOM', '--outDir', 'output', 'consumer.ts'], scratch);
    run(process.execPath, ['output/consumer.js'], scratch);
    run(process.execPath, ['--input-type=commonjs', '-e',
      'const api=require("@leepepe/loki-web"); if(typeof api.LokiTelemetry!=="function" || api.buildPushBody([]).streams.length!==0) throw Error("CJS exports");'], scratch);
    const digest = createHash('sha256').update(await readFile(artifact)).digest('hex');
    console.log(`WEB_DISTRIBUTION_OK ${registry.version} sha256=${digest}`);
  } finally {
    // Only the exact directory this process created is removed.
    await rm(scratch, {recursive: true});
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) await main();
