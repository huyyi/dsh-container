import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { test } from 'node:test';
import { audit, loadConfig, directoryName, writeJson } from '../plugin/common.mjs';
import { copyRuntime } from '../plugin/runtime.mjs';

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'repack-test-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  return root;
}
function pkg(directory, manifest, script = '') {
  fs.mkdirSync(directory, { recursive: true });
  writeJson(path.join(directory, 'package.json'), { main: 'index.cjs', ...manifest });
  fs.writeFileSync(path.join(directory, 'index.cjs'), script);
}

test('configuration requires explicit build flag, exact version and pinned build source', t => {
  const root = fixture(t);
  const file = path.join(root, 'plugins.json');
  const plugin = { name: '@scope/plugin', version: '1.2.3', pack_build_deps: false };
  writeJson(file, { schema_version: 1, plugins: [plugin] });
  assert.deepEqual(loadConfig(file), [plugin]);
  assert.equal(directoryName(plugin, '0.2.2-rc.2'), 'scope--plugin-1.2.3-dsh-0.2.2-rc.2');
  for (const change of [{ pack_build_deps: undefined }, { pack_build_deps: 'false' },
    { version: '^1.2.3' }, { name: '../outside' }, { pack_build_deps: true }]) {
    writeJson(file, { schema_version: 1, plugins: [{ ...plugin, ...change }] });
    assert.throws(() => loadConfig(file));
  }
  writeJson(file, { schema_version: 1, plugins: [plugin] });
  assert.throws(() => loadConfig(file, 'missing'), /not in config/);
});

test('scoped name sanitization collisions are rejected before downloads', t => {
  const root = fixture(t);
  const file = path.join(root, 'plugins.json');
  writeJson(file, { schema_version: 1, plugins: [
    { name: '@scope/plugin', version: '1.0.0', pack_build_deps: false },
    { name: 'scope--plugin', version: '1.0.0', pack_build_deps: false },
  ] });
  assert.throws(() => loadConfig(file), /Duplicate/);
});

test('dependency versions and cycles survive relocation without producer modules', t => {
  const root = fixture(t);
  const source = path.join(root, 'source');
  pkg(source, { name: 'plugin', version: '1.0.0', dependencies: { left: '1.0.0', right: '1.0.0' } },
    "module.exports = [require('left'), require('right')];");
  for (const [branch, version] of [['left', '1.0.0'], ['right', '2.0.0']]) {
    const directory = path.join(source, 'node_modules', branch);
    pkg(directory, { name: branch, version: '1.0.0', dependencies: { leaf: version } }, "module.exports = require('leaf').version;");
    pkg(path.join(directory, 'node_modules/leaf'), { name: 'leaf', version, dependencies: { [branch]: '1.0.0' } },
      `module.exports = {version: '${version}', cycle: () => require('${branch}')};`);
  }
  const output = path.join(root, 'producer/plugin');
  const graph = copyRuntime(source, output, () => undefined);
  assert.equal(graph.packages.filter(p => p.name === 'leaf').length, 2);
  const before = audit(output);
  fs.renameSync(path.dirname(output), path.join(root, 'relocated'));
  fs.rmSync(source, { recursive: true });
  const moved = path.join(root, 'relocated/plugin');
  assert.deepEqual(audit(moved), before);
  const require = createRequire(path.join(moved, 'package.json'));
  assert.deepEqual(require('./index.cjs'), ['1.0.0', '2.0.0']);
});

test('a compatible host peer wins over a plugin development copy', t => {
  const root = fixture(t);
  const source = path.join(root, 'source');
  const hostPeer = path.join(root, 'host-peer');
  pkg(source, { name: 'plugin', version: '1.0.0', peerDependencies: { singleton: '^1.0.0' } });
  pkg(path.join(source, 'node_modules/singleton'), { name: 'singleton', version: '1.0.0' });
  pkg(hostPeer, { name: 'singleton', version: '1.1.0' });
  const output = path.join(root, 'output');
  const graph = copyRuntime(source, output, () => hostPeer);
  assert.equal(graph.packages.length, 1);
  assert.equal(fs.realpathSync(path.join(output, 'node_modules/singleton')), hostPeer);
});

test('missing required dependencies fail while absent optional dependencies are allowed', t => {
  const root = fixture(t);
  const source = path.join(root, 'source');
  pkg(source, { name: 'plugin', version: '1.0.0', dependencies: { missing: '1.0.0' } });
  assert.throws(() => copyRuntime(source, path.join(root, 'bad'), () => undefined), /Missing dependency/);
  pkg(source, { name: 'plugin', version: '1.0.0', optionalDependencies: { missing: '1.0.0' } });
  assert.doesNotThrow(() => copyRuntime(source, path.join(root, 'good'), () => undefined));
});

test('external links and absolute producer links fail; hashes detect content changes', t => {
  const root = fixture(t);
  const directory = path.join(root, 'plugin');
  pkg(directory, { name: 'plugin', version: '1.0.0' });
  const before = audit(directory);
  fs.appendFileSync(path.join(directory, 'index.cjs'), 'changed');
  assert.notDeepEqual(audit(directory), before);
  fs.symlinkSync('/etc/passwd', path.join(directory, 'external'));
  assert.throws(() => audit(directory), /Nonportable/);
  fs.unlinkSync(path.join(directory, 'external'));
  fs.symlinkSync(path.join(directory, 'index.cjs'), path.join(directory, 'absolute'));
  assert.throws(() => audit(directory), /Absolute package link/);
});
