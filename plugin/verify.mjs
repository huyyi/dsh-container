import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
import { execFileSync } from 'node:child_process';
import { read, run, hash, audit, environment, inside } from './common.mjs';

const root = path.resolve(process.argv[2]);
const env = environment();
assert.deepEqual(fs.readdirSync('/sys/class/net'), ['lo'], 'Verification must run with --network none');
const directories = fs.readdirSync(root);
assert(directories.length, 'No plugin output');
for (const name of directories) {
  const directory = path.join(root, name);
  const manifest = JSON.parse(fs.readFileSync(path.join(directory, 'offline-manifest.json')));
  assert.equal(manifest.schema_version, 1);
  for (const key of ['image_id', 'version', 'arch', 'node']) assert.equal(manifest.host[key], env[key], `Host mismatch: ${key}`);
  const plugin = path.join(directory, 'plugin');
  assert.deepEqual(audit(plugin, true), manifest.files.plugin, 'Runtime checksum or link mismatch');
  assert.equal(read(plugin).name, manifest.plugin.name);
  assert.equal(read(plugin).version, manifest.plugin.version);
  for (const dependency of manifest.host_packages) assert.equal(read(dependency.path).version, dependency.version);
  for (const [file, expected] of Object.entries(manifest.files.extra ?? {})) {
    const absolute = path.resolve(directory, file);
    assert(inside(directory, absolute));
    assert.equal(hash(absolute), expected);
  }
  run('dsh', ['plugin', '--profile', 'web', 'add', `link:${plugin}`, '--offline', '--ignore-scripts']);
  const config = execFileSync('dsh', ['--profile', 'web', '--dump-config'], { encoding: 'utf8' });
  assert(config.includes(manifest.plugin.name), 'Plugin missing from resolved dsh config');
  const metadata = read(plugin);
  const exported = metadata.exports?.['.'] ?? metadata.exports;
  function entry(value) {
    if (typeof value === 'string') return value;
    for (const condition of ['node', 'import', 'default']) {
      if (value?.[condition]) {
        const result = entry(value[condition]);
        if (result) return result;
      }
    }
  }
  const main = entry(exported) ?? metadata.main;
  assert.equal(typeof main, 'string', 'Missing runtime entry point');
  await import(pathToFileURL(path.resolve(plugin, main)));
  const build = path.join(directory, 'build');
  if (manifest.plugin.pack_build_deps) {
    assert.deepEqual(audit(build), manifest.files.build, 'Build checksum or link mismatch');
    const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'offline-build-'));
    try {
      fs.cpSync(build, temporary, { recursive: true, dereference: false, verbatimSymlinks: true });
      assert.deepEqual(manifest.build_command, ['npm', 'run', 'build']);
      run('npm', ['run', 'build'], temporary);
      if (manifest.plugin.recipe === 'genui-intranet') {
        assert(fs.statSync(path.join(temporary, 'lib/assets/echarts-full.js')).size > 0);
        assert(fs.statSync(path.join(temporary, 'lib/assets/maplibre.js')).size > 0);
        assert.equal(JSON.parse(fs.readFileSync(path.join(temporary, 'assets/maps/index.json'))).maps.length, 38);
      }
    } finally { fs.rmSync(temporary, { recursive: true, force: true }); }
  } else {
    assert(!fs.existsSync(build), 'Runtime-only package unexpectedly includes build dependencies');
    assert.equal(manifest.files.build, undefined);
  }
  console.log(`PASS: ${manifest.plugin.name}@${manifest.plugin.version}: checksums, relocated read-only package, offline installation, config and import${manifest.plugin.pack_build_deps ? ', offline rebuild' : ''}`);
}
