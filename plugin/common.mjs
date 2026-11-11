import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';

export const host = '/opt/deepseek-harness';
export const read = directory => JSON.parse(fs.readFileSync(path.join(directory, 'package.json'), 'utf8'));
export const run = (command, args, cwd) => execFileSync(command, args, { cwd, stdio: 'inherit' });
export const inside = (root, file) => file === root || file.startsWith(root + path.sep);
export const hash = file => createHash('sha256').update(fs.readFileSync(file)).digest('hex');

export function loadConfig(file, only = '') {
  const config = JSON.parse(fs.readFileSync(file === '-' ? 0 : file, 'utf8'));
  if (config.schema_version !== 1 || !Array.isArray(config.plugins) || !config.plugins.length) {
    throw Error('Expected schema_version=1 and a nonempty plugins array');
  }
  const names = new Set();
  for (const plugin of config.plugins) {
    if (!/^(@[a-z0-9][a-z0-9._-]*\/)?[a-z0-9][a-z0-9._-]*$/.test(plugin.name)
      || !/^\d+\.\d+\.\d+(?:-[\w.-]+)?(?:\+[\w.-]+)?$/.test(plugin.version)
      || typeof plugin.pack_build_deps !== 'boolean') throw Error('Invalid plugin name, exact version or pack_build_deps');
    const key = directoryName(plugin, 'host');
    if (names.has(key)) throw Error(`Duplicate plugin output: ${plugin.name}@${plugin.version}`);
    names.add(key);
    if (plugin.source && (!/^https:\/\//.test(plugin.source.url) || !/^[a-f0-9]{64}$/.test(plugin.source.sha256))) {
      throw Error('Source requires an HTTPS tarball URL and SHA-256');
    }
    if (plugin.pack_build_deps && !plugin.source) throw Error(`Build dependencies require locked source: ${plugin.name}`);
    if (plugin.recipe && (plugin.recipe !== 'genui-intranet' || plugin.name !== '@changfenhuang/dsh-genui'
      || plugin.version !== '0.16.0' || !plugin.source)) throw Error('Unsupported recipe or recipe version');
  }
  const selected = config.plugins.filter(plugin => !only || plugin.name === only);
  if (!selected.length) throw Error(`Plugin not in config: ${only}`);
  return selected;
}

export function directoryName(plugin, version) {
  return `${plugin.name.replace(/^@/, '').replaceAll('/', '--')}-${plugin.version}-dsh-${version}`;
}

export function environment() {
  const metadata = JSON.parse(process.env.REPACK_IMAGE_METADATA);
  const version = execFileSync('dsh', ['--version'], { encoding: 'utf8' }).trim();
  const match = version.match(/(?:^|\s)v?(\d+\.\d+\.\d+(?:-[\w.-]+)?(?:\+[\w.-]+)?)(?:\s|$)/);
  if (!match) throw Error(`Cannot resolve dsh host version: ${version}`);
  return { version: match[1], image: process.env.REPACK_IMAGE, image_id: metadata.Id,
    repo_digests: metadata.RepoDigests ?? [], platform: process.platform, arch: process.arch,
    node: process.version };
}

export function audit(root, allowedHost = false) {
  const files = {};
  function visit(directory) {
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      const file = path.join(directory, entry.name);
      const relative = path.relative(root, file);
      if (entry.isSymbolicLink()) {
        const target = fs.realpathSync(file);
        if (!inside(root, target) && !(allowedHost && inside(host, target))) throw Error(`Nonportable link: ${relative}`);
        // 包内链接必须为相对路径，否则换挂载点后会失效。
        if (inside(root, target) && path.isAbsolute(fs.readlinkSync(file))) throw Error(`Absolute package link: ${relative}`);
        files[relative] = { link: fs.readlinkSync(file) };
      } else if (entry.isDirectory()) visit(file);
      else if (entry.isFile()) files[relative] = hash(file);
      else throw Error(`Unsupported file: ${relative}`);
    }
  }
  visit(root);
  return files;
}

export function writeJson(file, value) {
  fs.writeFileSync(file, JSON.stringify(value, null, 2) + '\n');
}
