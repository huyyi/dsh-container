import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { read, run, hash, loadConfig, directoryName, environment, audit, writeJson } from './common.mjs';
import { hostResolver, copyRuntime, excluded } from './runtime.mjs';

const tools = path.dirname(fileURLToPath(import.meta.url));
const [config, output, only] = process.argv.slice(2);
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-repack-'));
try {
  const plugins = loadConfig(config, only);
  const env = environment();
  const resolveHost = hostResolver();
  fs.mkdirSync(output, { recursive: true });
  for (const plugin of plugins) {
    const destination = path.join(output, directoryName(plugin, env.version));
    if (fs.existsSync(destination)) throw Error(`Output already exists: ${destination}`);
    const working = path.join(temporary, String(plugins.indexOf(plugin)));
    const source = path.join(working, 'source');
    fs.mkdirSync(source, { recursive: true });
    console.log(`Packing ${plugin.name}@${plugin.version} for dsh ${env.version} (${env.arch})`);
    if (plugin.source) {
      const tarball = path.join(working, 'source.tgz');
      run('curl', ['--fail', '--location', '--retry', '2', '--proto', '=https', '--proto-redir', '=https', plugin.source.url, '-o', tarball]);
      if (hash(tarball) !== plugin.source.sha256) throw Error('Source SHA-256 mismatch');
      run('tar', ['-xzf', tarball, '--strip-components=1', '--no-same-owner', '-C', source]);
    } else {
      const result = JSON.parse(execFileSync('npm', ['pack', `${plugin.name}@${plugin.version}`, '--ignore-scripts', '--json'],
        { cwd: working, encoding: 'utf8', maxBuffer: 8 * 1024 * 1024 }));
      run('tar', ['-xzf', path.join(working, result[0].filename), '--strip-components=1', '--no-same-owner', '-C', source]);
    }
    const metadata = read(source);
    if (metadata.name !== plugin.name || metadata.version !== plugin.version || !metadata.dsh?.bundle?.patch) {
      throw Error('Source must match configured plugin name/version and declare dsh.bundle.patch');
    }
    if (plugin.recipe) {
      const recipe = await import(path.join(tools, 'recipes', plugin.recipe + '.mjs'));
      await recipe.prepare(source, working);
    }
    if (plugin.source) {
      if (!fs.existsSync(path.join(source, 'pnpm-lock.yaml'))) throw Error('Source build requires pnpm-lock.yaml');
      run('pnpm', ['install', '--frozen-lockfile', '--ignore-scripts', '--store-dir', path.join(working, 'build-store')], source);
      // 生产端生成运行包，消费端必须使用交付依赖再次禁网重建。
      run('npm', ['run', 'build'], source);
    }
    const runtime = path.join(working, 'runtime');
    fs.mkdirSync(runtime);
    const dependencies = { ...metadata.dependencies, ...metadata.optionalDependencies };
    for (const [name, spec] of Object.entries(metadata.peerDependencies ?? {})) {
      if (resolveHost(name, spec)) delete dependencies[name];
    }
    writeJson(path.join(runtime, 'package.json'), { private: true, dependencies });
    run('pnpm', ['install', '--prod', '--ignore-scripts', '--config.auto-install-peers=false',
      '--store-dir', path.join(working, 'runtime-store')], runtime);
    const prepared = path.join(working, 'prepared');
    fs.cpSync(source, prepared, { recursive: true, dereference: false, verbatimSymlinks: true, filter: excluded });
    if (fs.existsSync(path.join(runtime, 'node_modules'))) fs.symlinkSync(path.join(runtime, 'node_modules'), path.join(prepared, 'node_modules'));
    fs.mkdirSync(destination);
    const runtimeDirectory = path.join(destination, 'plugin');
    const graph = copyRuntime(prepared, runtimeDirectory, resolveHost);
    const files = { plugin: audit(runtimeDirectory, true) };
    if (plugin.pack_build_deps) {
      const build = path.join(destination, 'build');
      fs.cpSync(source, build, { recursive: true, dereference: false, verbatimSymlinks: true });
      files.build = audit(build);
    }
    if (plugin.recipe) {
      fs.copyFileSync(path.join(tools, 'recipes/genui-intranet.patch'), path.join(destination, 'genui-intranet.patch'));
      fs.copyFileSync(path.join(tools, 'recipes/genui-intranet.md'), path.join(destination, 'GENUI.md'));
      files.extra = { 'genui-intranet.patch': hash(path.join(destination, 'genui-intranet.patch')),
        'GENUI.md': hash(path.join(destination, 'GENUI.md')) };
    }
    const instructions = `# ${plugin.name}@${plugin.version}\n\nHost: ${env.image}\n\nImage ID: ${env.image_id}\n\ndsh: ${env.version}; architecture: ${env.arch}; Node: ${env.node}.\n\n`
      + 'Use the same image digest and architecture. Mount `plugin/` outside `/home/dsh` at `/opt/offline-plugins/package` and keep it mounted after installation.\n\n'
      + '```sh\ndsh plugin --profile web add link:/opt/offline-plugins/package --offline --ignore-scripts\ndsh --profile web --dump-config\ndsh-restart\n```\n\n'
      + 'Newly added bundles may be enabled by dsh. An existing disabled bundle needs enabling in Plugin Manager. External services remain separate requirements.\n'
      + (plugin.pack_build_deps ? '\n`build/` contains the locked source and development dependencies. Copy it to a writable directory in the same image, disable container networking, and run `npm run build`. No install step is required. This rebuild does not update `plugin/`; rerun the packer to create a new runtime package.\n' : '');
    fs.writeFileSync(path.join(destination, 'INSTALL.md'), instructions);
    files.extra = { ...files.extra, 'INSTALL.md': hash(path.join(destination, 'INSTALL.md')) };
    writeJson(path.join(destination, 'offline-manifest.json'), {
      schema_version: 1, plugin, host: env, ...graph, files,
      build_command: plugin.pack_build_deps ? ['npm', 'run', 'build'] : null,
    });
  }
} catch (error) {
  console.error(`offline_repack: ${error.stack}`);
  process.exitCode = 1;
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
