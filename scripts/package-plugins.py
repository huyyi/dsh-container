#!/usr/bin/env python3
"""在目标架构的 dsh 镜像中生成独立离线插件目录。"""
import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile


def run(*args, cwd=None, capture=False):
    return subprocess.run(args, cwd=cwd, check=True, text=True,
                          stdout=subprocess.PIPE if capture else None).stdout


def build(catalog, output):
    output.mkdir(parents=True, exist_ok=True)
    arch = {"x86_64": "amd64", "aarch64": "arm64"}[os.uname().machine]
    host = Path('/opt/deepseek-harness')
    version = json.loads((host / 'apps/cli/package.json').read_text())['version']
    manifest = dict(schema=1, architecture=arch, dsh=version,
                    python=f'{sys.version_info.major}.{sys.version_info.minor}', plugins=[])
    specs = json.loads(catalog.read_text())['plugins']
    if len(specs) != len(set(specs)):
        raise ValueError('Duplicate plugin specifications')
    for spec in specs:
        if not re.fullmatch(r'(?:@[a-z0-9._-]+/)?[a-z0-9._-]+@\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?', spec):
            raise ValueError(f'Expected package@exact-version: {spec}')
        print(f'Packaging {spec}', flush=True)
        name, version_pin = spec.rsplit('@', 1)
        if not name or not version_pin or version_pin[0] not in '0123456789':
            raise ValueError(f'Expected package@exact-version: {spec}')
        folder = output / 'plugins' / name.replace('/', '__').lstrip('@')
        folder.mkdir(parents=True)
        with tempfile.TemporaryDirectory() as temp:
            archive = json.loads(run('npm', 'pack', spec, '--json', '--ignore-scripts', cwd=temp, capture=True))[0]
            packed = Path(temp) / archive['filename']
            with tarfile.open(packed) as tar:
                # bookworm 的 Python 3.11 尚无 extraction filter，逐项验证路径与链接。
                for member in tar.getmembers():
                    target = (folder / member.name).resolve()
                    if not target.is_relative_to(folder) or not (
                            member.isfile() or member.isdir() or member.issym() or member.islnk()):
                        raise ValueError(f'Unsafe archive entry: {member.name}')
                    if member.issym() or member.islnk():
                        base = target.parent if member.issym() else folder
                        if Path(member.linkname).is_absolute() or not (
                                base / member.linkname).resolve().is_relative_to(folder):
                            raise ValueError(f'Unsafe archive link: {member.name}')
                    tar.extract(member, folder)
            package = folder / 'package'
            for item in package.iterdir():
                shutil.move(str(item), folder)
            package.rmdir()
        meta = json.loads((folder / 'package.json').read_text())
        if meta['name'] != name or meta['version'] != version_pin:
            raise ValueError(f'Unexpected package identity for {spec}')
        row = dict(spec=spec, name=name, version=meta['version'], path=str(folder.relative_to(output)),
                   integrity=archive['integrity'])
        if not meta.get('dsh', {}).get('bundle', {}).get('patch'):
            raise ValueError(f'{spec} is not a dsh bundle')
        # 复用宿主的完整规则，包含 engines 与 dsh peer 版本范围。
        issue = run('node', '--input-type=module', '-e', '''
import fs from 'node:fs';
import {evaluatePluginCompatibility} from '/opt/deepseek-harness/packages/boot/app-boot/lib/index.js';
const manifest = JSON.parse(fs.readFileSync(process.argv[1]));
console.log(JSON.stringify(evaluatePluginCompatibility(manifest, {}, process.argv[2]) ?? null));
''', str(folder / 'package.json'), version, capture=True).strip()
        if json.loads(issue) is not None:
            row.update(status='skipped', reason=json.loads(issue))
            print(f'Skipping {spec}: {issue}', flush=True)
            shutil.rmtree(folder)
            manifest['plugins'].append(row)
            continue
        # 根包的 peer 也必须落在插件目录内；保留发布者的原始清单供审计。
        shutil.copyfile(folder / 'package.json', folder / 'package.source.json')
        declared = {**meta.get('dependencies', {}), **meta.get('devDependencies', {})}
        peers = []
        for peer, constraint in meta.get('peerDependencies', {}).items():
            if peer not in declared and not meta.get('peerDependenciesMeta', {}).get(peer, {}).get('optional'):
                selected = version if peer.startswith('@deepseek-ai/dsh-') else constraint
                peers.append(f'{peer}@{selected}')
        args = ['npm', 'install', '--include=dev', '--include=optional', '--legacy-peer-deps',
                '--ignore-scripts', '--no-audit', '--no-fund']
        if peers:
            args.extend(['--save-dev', *peers])
        run(*args, cwd=folder)
        # 对依赖执行原生编译等生命周期；根包脚本可能写 HOME，不能在此运行。
        # 依赖脚本的 HOME/cache 也收进插件目录，避免丢失额外下载的物料。
        build_env = dict(os.environ, HOME=str(folder / '.build-home'),
                         XDG_CACHE_HOME=str(folder / '.cache'))
        lifecycle_names = set()
        for modules in folder.rglob('node_modules'):
            if not modules.is_dir():
                continue
            dependencies = list(modules.glob('*/package.json'))
            dependencies += list(modules.glob('@*/*/package.json'))
            for dependency in dependencies:
                dep = json.loads(dependency.read_text())
                if (any(key in dep.get('scripts', {}) for key in ('preinstall', 'install', 'postinstall'))
                        or dependency.with_name('binding.gyp').exists()):
                    lifecycle_names.add(dep['name'])
        for dependency in sorted(lifecycle_names):
            subprocess.run(['npm', 'rebuild', dependency, '--offline'], cwd=folder,
                           env=build_env, check=True)
        requirements = sorted(p for p in folder.rglob('requirements*.txt') if 'node_modules' not in p.parts)
        row['requirements'] = [str(p.relative_to(folder)) for p in requirements]
        if name == 'dsh-office-kit' and not requirements:
            raise ValueError('office-kit Python requirements were not found')
        if requirements:
            wheelhouse = folder / 'wheelhouse'
            wheelhouse.mkdir()
            with tempfile.TemporaryDirectory() as temp:
                run('uv', 'venv', '--seed', '--python', '/usr/bin/python3', temp + '/venv')
                args = [temp + '/venv/bin/python', '-m', 'pip', 'wheel', '--wheel-dir', str(wheelhouse)]
                for req in requirements:
                    args.extend(['-r', str(req)])
                run(*args)
        # 清单、锁文件与所有依赖一起交付；禁止软链逃逸目录。
        for path in folder.rglob('*'):
            if path.is_symlink() and not path.resolve().is_relative_to(folder.resolve()):
                raise ValueError(f'External symlink: {path}')
        row['status'] = 'ready'
        manifest['plugins'].append(row)
    (output / 'plugins.json').write_text(json.dumps(manifest, indent=2) + '\n')
    shutil.copyfile(Path(__file__).with_name('install-plugins.sh'), output / 'install.sh')
    shutil.copyfile(Path(__file__).with_name('install-plugins.py'), output / 'install-plugins.py')
    # 文件级校验也覆盖解压后、安装前的搬运完整性。
    checksums = {str(p.relative_to(output)): hashlib.sha256(p.read_bytes()).hexdigest()
                 for p in sorted(output.rglob('*')) if p.is_file() and not p.is_symlink()}
    (output / 'SHA256SUMS.json').write_text(json.dumps(checksums, indent=2) + '\n')


if __name__ == '__main__':
    build(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())
