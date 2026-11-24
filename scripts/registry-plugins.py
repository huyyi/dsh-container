#!/usr/bin/env python3
"""从锁文件与 npm 缓存导出原始 registry 包，不重新打包 node_modules。"""
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import sys
import tempfile
import tarfile


def build_registry(payload, output):
    manifest = json.loads((payload / 'plugins.json').read_text())
    requests = {}

    def add(meta, integrity, source, plugin):
        if not integrity:
            raise ValueError(f"Missing registry integrity: {meta['name']}@{meta['version']}")
        spec = f"{meta['name']}@{meta['version']}"
        row = requests.setdefault(spec, dict(name=meta['name'], version=meta['version'],
                                            integrity=integrity, source=source, plugins=[]))
        if row['integrity'] != integrity:
            values = row.setdefault('integrities', [row['integrity']])
            if integrity not in values:
                values.append(integrity)
        if plugin not in row['plugins']:
            row['plugins'].append(plugin)

    for plugin in manifest['plugins']:
        if plugin['status'] != 'ready':
            continue
        folder = (payload / plugin['path']).resolve()
        if not folder.is_relative_to(payload):
            raise ValueError('Plugin directory escapes payload')
        meta = json.loads((folder / 'package.source.json').read_text())
        add(meta, plugin['integrity'], plugin['spec'], plugin['spec'])
        lock = json.loads((folder / 'package-lock.json').read_text())
        if lock.get('lockfileVersion', 0) < 2:
            raise ValueError('Registry export requires npm lockfileVersion >= 2')
        for location, entry in lock['packages'].items():
            if not location:
                continue
            package = (folder / location).resolve()
            if not package.is_relative_to(folder):
                raise ValueError(f'Lockfile path escapes plugin: {location}')
            # 只导出当前架构实际安装的依赖；其他架构由对应原生 runner 补齐。
            if not (package / 'package.json').is_file():
                continue
            if entry.get('inBundle'):
                continue
            source = entry.get('resolved', '')
            if entry.get('link') or not source.startswith(('https://', 'http://')):
                raise ValueError(f'Not an original registry tarball: {location}: {source}')
            dependency = json.loads((package / 'package.json').read_text())
            if dependency['version'] != entry['version']:
                raise ValueError(f'Installed version differs from lockfile: {location}')
            add(dependency, entry.get('integrity'), source, plugin['spec'])
    output.mkdir(parents=True)
    for spec, row in requests.items():
        row['file'] = 'packages/' + hashlib.sha256(spec.encode()).hexdigest() + '.tgz'
    # 用户全局 prefix 不一定是 npm 自己的安装位置，沿实际 CLI 的软链定位。
    npm_home = str(Path(shutil.which('npm')).resolve().parent.parent)
    cache = subprocess.check_output(['npm', 'config', 'get', 'cache'], text=True).strip()
    with tempfile.TemporaryDirectory() as temp:
        request_file = Path(temp) / 'requests.json'
        request_file.write_text(json.dumps(sorted(requests.values(), key=lambda row: (row['name'], row['version']))))
        subprocess.run(['node', str(Path(__file__).with_name('registry-tarballs.mjs')),
                        str(request_file), str(output), npm_home, cache], check=True)
    result = json.loads((output / 'packages.json').read_text())
    for row in result['packages']:
        with tarfile.open(output / row['file'], 'r|gz') as tar:
            packed_meta = None
            for member in tar:
                # @types 等历史包使用任意单层目录前缀，npm 安装时会剥掉该前缀。
                parts = PurePosixPath(member.name).parts
                if member.isfile() and len(parts) == 2 and parts[-1] == 'package.json':
                    packed_meta = json.load(tar.extractfile(member))
                    break
            if not packed_meta or (packed_meta.get('name'), packed_meta.get('version')) != (row['name'], row['version']):
                raise ValueError(f"Original tarball identity mismatch: {row['name']}@{row['version']}")
    result.update(schema=1, architecture=manifest['architecture'], dsh=manifest['dsh'],
                  plugins=[{key: p[key] for key in ('spec', 'name', 'version')}
                           for p in manifest['plugins'] if p['status'] == 'ready'])
    (output / 'packages.json').write_text(json.dumps(result, indent=2) + '\n')
    shutil.copyfile(Path(__file__).with_name('import-registry.py'), output / 'import-registry.py')
    shutil.copyfile(Path(__file__).with_name('import-registry.sh'), output / 'import.sh')
    print(f"Registry export: {len(requests)} original npm packages ({manifest['architecture']})", flush=True)


if __name__ == '__main__':
    build_registry(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())
