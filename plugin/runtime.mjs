import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { host, read, inside } from './common.mjs';

export function hostResolver() {
  const require = createRequire(path.join(host, 'package.json'));
  let semver;
  try { semver = require('semver'); }
  catch {
    const store = path.join(host, 'node_modules/.pnpm');
    const entry = fs.readdirSync(store).find(name => name.startsWith('semver@'));
    if (!entry) throw Error('Host semver package is required to validate peer versions');
    semver = require(path.join(store, entry, 'node_modules/semver'));
  }
  const index = new Map();
  function add(directory) {
    const real = fs.realpathSync(directory);
    const manifest = read(real);
    if (!manifest.name) return;
    const candidates = index.get(manifest.name) ?? new Set();
    candidates.add(real);
    index.set(manifest.name, candidates);
  }
  function workspace(directory) {
    if (!fs.existsSync(directory)) return;
    if (fs.existsSync(path.join(directory, 'package.json'))) { add(directory); return; }
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      if (entry.isDirectory() && !entry.name.startsWith('.') && entry.name !== 'node_modules') workspace(path.join(directory, entry.name));
    }
  }
  workspace(path.join(host, 'packages'));
  for (const app of ['apps/cli', 'apps/web', '']) {
    const directory = path.join(host, app, 'node_modules');
    if (!fs.existsSync(directory)) continue;
    for (const name of fs.readdirSync(directory)) {
      if (name.startsWith('.')) continue;
      const entry = path.join(directory, name);
      if (name.startsWith('@')) {
        for (const child of fs.readdirSync(entry)) if (fs.existsSync(path.join(entry, child, 'package.json'))) add(path.join(entry, child));
      } else if (fs.existsSync(path.join(entry, 'package.json'))) add(entry);
    }
  }
  return (name, spec) => {
    const candidates = [...(index.get(name) ?? [])].filter(directory =>
      semver.satisfies(read(directory).version, spec, { includePrerelease: true }));
    // 工作区优先，避免将宿主单例替换成插件的开发副本。
    const workspaces = candidates.filter(directory => inside(path.join(host, 'packages'), directory));
    const selected = workspaces.length ? workspaces : candidates;
    if (selected.length > 1 && new Set(selected.map(directory => read(directory).version)).size > 1) {
      throw Error(`Ambiguous host dependency ${name}@${spec}`);
    }
    return selected[0];
  };
}

export const excluded = file => !['node_modules', '.git', '.npmrc', '.env', '.pnpm-store'].includes(path.basename(file));

export function copyRuntime(source, destination, resolveHost) {
  const seen = new Map();
  const packages = [];
  const hostPackages = new Map();
  function locate(name, from) {
    for (let current = from; ; current = path.dirname(current)) {
      const candidate = path.join(current, 'node_modules', name);
      if (fs.existsSync(path.join(candidate, 'package.json'))) return fs.realpathSync(candidate);
      if (current === path.dirname(current)) return undefined;
    }
  }
  function copy(from, to) {
    from = fs.realpathSync(from);
    if (seen.has(from)) return seen.get(from);
    seen.set(from, to);
    const manifest = read(from);
    fs.cpSync(from, to, { recursive: true, dereference: false, verbatimSymlinks: true, filter: excluded });
    packages.push({ name: manifest.name, version: manifest.version, directory: path.relative(destination, to) || '.' });
    const deps = { ...manifest.peerDependencies, ...manifest.dependencies, ...manifest.optionalDependencies };
    for (const [name, spec] of Object.entries(deps)) {
      if (!/^(@[^/]+\/)?[^/.][^/]*$/.test(name) || name.includes('..')) throw Error(`Invalid dependency name: ${name}`);
      const peer = Object.hasOwn(manifest.peerDependencies ?? {}, name);
      const optional = Object.hasOwn(manifest.optionalDependencies ?? {}, name) || (peer && manifest.peerDependenciesMeta?.[name]?.optional);
      const supplied = peer ? resolveHost(name, manifest.peerDependencies[name]) : undefined;
      const resolved = locate(name, from);
      let target;
      if (supplied) {
        target = supplied;
        hostPackages.set(name, { name, version: read(target).version, path: target });
      } else if (resolved) {
        if (peer && inside(host, resolved)) throw Error(`Incompatible host peer: ${name}@${spec}`);
        target = copy(resolved, path.join(destination, '.offline-deps', String(seen.size)));
      } else if (optional) continue;
      else throw Error(`Missing dependency ${name}@${spec} required by ${manifest.name}`);
      const link = path.join(to, 'node_modules', name);
      fs.mkdirSync(path.dirname(link), { recursive: true });
      fs.symlinkSync(inside(destination, target) ? path.relative(path.dirname(link), target) : target, link);
    }
    // 为运行时调用的依赖命令重建可执行链接。
    for (const name of Object.keys(deps)) {
      const dependency = path.join(to, 'node_modules', name);
      if (!fs.existsSync(dependency)) continue;
      const metadata = read(dependency);
      const bins = typeof metadata.bin === 'string' ? { [metadata.name.split('/').pop()]: metadata.bin } : metadata.bin ?? {};
      for (const [command, file] of Object.entries(bins)) {
        if (path.basename(command) !== command) throw Error('Invalid executable name');
        const link = path.join(to, 'node_modules/.bin', command);
        fs.mkdirSync(path.dirname(link), { recursive: true });
        if (!fs.existsSync(link)) fs.symlinkSync(path.relative(path.dirname(link), path.resolve(dependency, file)), link);
      }
    }
    return to;
  }
  copy(source, destination);
  return { packages, host_packages: [...hostPackages.values()] };
}
