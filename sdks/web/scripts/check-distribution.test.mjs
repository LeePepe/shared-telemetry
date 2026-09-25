import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, cp, readFile, writeFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {checkContract} from './check-distribution.mjs';

const sdk = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

async function fixture(run) {
  const directory = await mkdtemp(path.join(tmpdir(), 'loki-web-contract-'));
  try {
    for (const name of ['ai', 'dist', 'package.json']) await cp(path.join(sdk, name), path.join(directory, name), {recursive: true});
    await run(directory);
  } finally { await rm(directory, {recursive: true}); }
}

test('valid contract and runtime export list', () => fixture(root => checkContract(root)));
test('missing document fails', () => fixture(async root => {
  await rm(path.join(root, 'ai/INTEGRATION.md'));
  await assert.rejects(checkContract(root), /WEB_AI_DOCUMENT/);
}));
test('mismatched installed version fails', () => fixture(async root => {
  const filename = path.join(root, 'package.json');
  const data = JSON.parse(await readFile(filename));
  data.version = '0.2.0';
  await writeFile(filename, JSON.stringify(data));
  await assert.rejects(checkContract(root), /WEB_AI_VERSION/);
}));
test('invalid registry schema fails', () => fixture(async root => {
  const filename = path.join(root, 'ai/registry.json');
  const data = JSON.parse(await readFile(filename));
  data.schemaVersion = 2;
  await writeFile(filename, JSON.stringify(data));
  await assert.rejects(checkContract(root), /WEB_AI_SCHEMA/);
}));
test('document cannot escape artifact', () => fixture(async root => {
  await writeFile(path.join(root, 'ai/README.md'), '[bad](../../outside.md)');
  await assert.rejects(checkContract(root), /WEB_AI_PATH/);
}));
test('runtime export removal fails', () => fixture(async root => {
  await writeFile(path.join(root, 'dist/index.js'), 'export const removed = true;');
  await assert.rejects(checkContract(root), /WEB_AI_API/);
}));
