#!/usr/bin/env python3
"""原始包导出及导入的端到端测试：本地模拟 registry，不访问或发布到公网。"""
import base64
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import threading
from urllib.parse import quote, unquote, urlparse

REPO = Path(__file__).resolve().parents[1]
loader = importlib.util.spec_from_file_location('registry_export', REPO / 'scripts/registry-plugins.py')
export = importlib.util.module_from_spec(loader)
loader.loader.exec_module(export)


class Registry(BaseHTTPRequestHandler):
    packages = {}
    blobs = {}
    writes = 0

    def log_message(self, *args):
        pass

    def reply(self, status, value):
        data = value if isinstance(value, bytes) else json.dumps(value).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/octet-stream' if isinstance(value, bytes) else 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = unquote(urlparse(self.path).path)
        if path in self.blobs:
            return self.reply(200, self.blobs[path])
        name = path.removeprefix('/npm/').rstrip('/')
        return self.reply(200, self.packages[name]) if name in self.packages else self.reply(404, {'error': 'not_found'})

    def do_PUT(self):
        data = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        name = data['name']
        record = self.packages.setdefault(name, dict(name=name, versions={}, **{'dist-tags': {}}))
        for version, manifest in data['versions'].items():
            if version in record['versions']:
                return self.reply(409, {'error': 'cannot overwrite version'})
            blob = base64.b64decode(next(iter(data['_attachments'].values()))['data'])
            assert manifest['dist']['shasum'] == hashlib.sha1(blob).hexdigest()
            assert manifest['dist']['integrity'] == 'sha512-' + base64.b64encode(hashlib.sha512(blob).digest()).decode()
            self.blobs[unquote(urlparse(manifest['dist']['tarball']).path)] = blob
            record['versions'][version] = manifest
        record['dist-tags'].update(data['dist-tags'])
        type(self).writes += 1
        self.reply(201, {'ok': True})


def command(*args, env, success=True):
    result = subprocess.run(args, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if success and result.returncode:
        raise AssertionError(f'{args}:\n{result.stdout}')
    if not success and not result.returncode:
        raise AssertionError(f'Unexpected success: {args}')
    return result.stdout


def main():
    server = ThreadingHTTPServer(('127.0.0.1', 0), Registry)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    registry = f'http://127.0.0.1:{server.server_port}/npm/'
    try:
        with tempfile.TemporaryDirectory() as temp:
            temp = Path(temp)
            cache = temp / 'cache'
            config = temp / 'npmrc'
            # 错误的 scope registry 用于确认显式目标会覆盖 scope 路由。
            config.write_text(f'//127.0.0.1:{server.server_port}/npm/:_authToken=fixture-token\n'
                              '@fixture:registry=http://127.0.0.1:1/\n')
            env = dict(os.environ, npm_config_cache=str(cache), npm_config_userconfig=str(config),
                       npm_config_update_notifier='false', npm_config_registry=registry)
            payload = temp / 'payload'
            payload.mkdir()
            bundles = []
            original = {}
            metas = {}
            for name, version, dependencies in [
                ('@fixture/dep', '1.0.0', {}), ('fixture-dev', '1.0.0', {}),
                ('fixture-child', '1.0.0', {'@fixture/dep': '1.0.0'}),
                ('fixture-child', '2.0.0', {'@fixture/dep': '1.0.0'}),
                ('fixture-a', '1.0.0', {'fixture-child': '1.0.0'}),
                ('fixture-b', '1.0.0', {'fixture-child': '2.0.0'}),
            ]:
                meta = dict(name=name, version=version, dependencies=dependencies,
                            scripts={'prepublishOnly': 'node -e "process.exit(88)"'},
                            publishConfig={'registry': 'http://127.0.0.1:1/', 'tag': 'unexpected', 'provenance': True})
                if name == 'fixture-dev':
                    meta.update(cpu=['arm64'], os=['linux'])
                if name in ('fixture-a', 'fixture-b'):
                    meta['devDependencies'] = {'fixture-dev': '1.0.0'}
                spec = f'{name}@{version}'
                archive = temp / (hashlib.sha256(spec.encode()).hexdigest() + '.tgz')
                with tarfile.open(archive, 'w:gz') as tar:
                    for filename, content in [('package.json', json.dumps(meta).encode()), ('index.js', b'original source\n')]:
                        prefix = name.split('/')[-1] if name.startswith('@') else 'package'
                        info = tarfile.TarInfo(prefix + '/' + filename)
                        info.size = len(content)
                        tar.addfile(info, io.BytesIO(content))
                data = archive.read_bytes()
                integrity = 'sha512-' + base64.b64encode(hashlib.sha512(data).digest()).decode()
                original[spec] = (data, integrity)
                metas[spec] = meta
                if name == 'fixture-dev':
                    Registry.blobs['/npm/fixture-dev/-/source.tgz'] = data
                else:
                    command('npm', 'cache', 'add', str(archive), '--ignore-scripts', env=env)
            for root, child in [('fixture-a', '1.0.0'), ('fixture-b', '2.0.0')]:
                folder = payload / 'plugins' / root
                folder.mkdir(parents=True)
                spec = f'{root}@1.0.0'
                (folder / 'package.source.json').write_text(json.dumps(metas[spec]))
                (folder / 'package.json').write_text(json.dumps(metas[spec]))
                # 这些安装后/额外下载的物料绝不能进入 registry 包。
                (folder / 'wheelhouse').mkdir()
                (folder / 'wheelhouse' / 'not-an-npm-package.whl').write_text('excluded')
                entries = {'': metas[spec]}
                for dep in [f'fixture-child@{child}', '@fixture/dep@1.0.0', 'fixture-dev@1.0.0']:
                    meta = metas[dep]
                    location = 'node_modules/' + meta['name']
                    installed = folder / location
                    installed.mkdir(parents=True)
                    (installed / 'package.json').write_text(json.dumps(meta))
                    (installed / 'index.js').write_text('modified build output')
                    integrity = original[dep][1]
                    if root == 'fixture-b' and meta['name'] == '@fixture/dep':
                        integrity = 'sha1-' + base64.b64encode(hashlib.sha1(original[dep][0]).digest()).decode()
                    entries[location] = dict(version=meta['version'], integrity=integrity,
                                             resolved=registry + quote(meta['name'], safe='') + '/-/source.tgz')
                entries['node_modules/fixture-other-arch'] = dict(version='1.0.0', optional=True)
                (folder / 'package-lock.json').write_text(json.dumps(dict(lockfileVersion=3, packages=entries)))
                bundles.append(dict(spec=spec, name=root, version='1.0.0', status='ready',
                                    integrity=original[spec][1], path='plugins/' + root))
            (payload / 'plugins.json').write_text(json.dumps(dict(architecture='amd64', dsh='fixture', plugins=bundles)))
            previous = os.environ.copy()
            os.environ.update(env)
            try:
                output = temp / 'registry'
                export.build_registry(payload, output)
            finally:
                os.environ.clear()
                os.environ.update(previous)
            index = json.loads((output / 'packages.json').read_text())
            assert len(index['packages']) == 6, 'dedup, multiple versions and dev dependencies must be preserved'
            for row in index['packages']:
                assert (output / row['file']).read_bytes() == original[f"{row['name']}@{row['version']}"][0]
            assert not list(output.rglob('*.whl'))
            importer = output / 'import-registry.py'
            command('python3', str(importer), '--verify-only', env=env)
            command('bash', str(output / 'import.sh'), registry, env=env)
            assert Registry.writes == 6
            assert all('offline-import' in value['dist-tags'] and 'unexpected' not in value['dist-tags']
                       for value in Registry.packages.values())
            again = command('python3', str(importer), registry, env=env)
            assert Registry.writes == 6 and again.count('Skipped existing') == 6
            # 从只有本地 registry 可用的全新 npm cache 安装，证明包之间可正常解析。
            app = temp / 'app'
            app.mkdir()
            (app / 'package.json').write_text(json.dumps(dict(name='fixture-app', version='1.0.0',
                dependencies={'fixture-a': '1.0.0', 'fixture-b': '1.0.0'})))
            command('npm', '--prefix', str(app), 'install', '--ignore-scripts', '--no-audit', '--no-fund',
                    '--legacy-peer-deps', '--registry', registry, f'--@fixture:registry={registry}',
                    '--cache', str(temp / 'fresh-cache'), env=env)
            assert (app / 'node_modules/@fixture/dep/package.json').exists()
            Registry.packages['fixture-a']['versions']['1.0.0']['dist']['integrity'] = 'sha512-conflict'
            assert 'different bytes' in command('python3', str(importer), registry, env=env, success=False)
            assert Registry.writes == 6
            (output / index['packages'][0]['file']).write_bytes(b'corrupted')
            assert 'Checksum mismatch' in command('python3', str(importer), '--verify-only', env=env, success=False)
            print('registry-plugins: original bytes, complete closure, dedup, scopes, idempotency, conflicts and corruption OK')
    finally:
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main()
