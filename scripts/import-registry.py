#!/usr/bin/env python3
"""校验原始 npm tarball，显式导入 registry；重复内容跳过，版本冲突报错。"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import subprocess
import sys
from urllib.parse import urlparse


def import_registry(root, registry=None):
    manifest = json.loads((root / 'packages.json').read_text())
    if manifest['schema'] != 1:
        raise ValueError('Unsupported registry manifest schema')
    packages = manifest['packages']
    seen = set()
    # 发布前先校验全部物料，损坏的文件不能造成部分导入。
    for row in packages:
        spec = f"{row['name']}@{row['version']}"
        if spec in seen:
            raise ValueError(f'Duplicate package: {spec}')
        seen.add(spec)
        file = (root / row['file']).resolve()
        if not file.is_relative_to(root):
            raise ValueError(f'Package path escapes bundle: {spec}')
        data = file.read_bytes()
        if (len(data) != row['size'] or hashlib.sha256(data).hexdigest() != row['sha256']
                or hashlib.sha1(data).hexdigest() != row['sha1']
                or 'sha512-' + base64.b64encode(hashlib.sha512(data).digest()).decode() != row['sha512']):
            raise ValueError(f'Checksum mismatch: {spec}')
    print(f'Verified {len(packages)} original npm packages', flush=True)
    if registry is None:
        return
    parsed = urlparse(registry)
    if parsed.scheme not in ('http', 'https') or not parsed.netloc:
        raise ValueError('Registry must be an explicit http(s) URL')
    for row in packages:
        spec = f"{row['name']}@{row['version']}"
        flags = ['--registry', registry]
        # 显式覆盖 scope registry，避免用户的 scope 配置将导入发往其他 registry。
        if row['name'].startswith('@'):
            flags.append(f"--{row['name'].split('/')[0]}:registry={registry}")
        viewed = subprocess.run(['npm', 'view', spec, 'dist', '--json', *flags],
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if viewed.returncode == 0:
            dist = json.loads(viewed.stdout)
            if dist.get('integrity'):
                identical = row['sha512'] in dist['integrity'].split()
                if not identical and dist['integrity'].startswith('sha1-'):
                    identical = base64.b64encode(bytes.fromhex(row['sha1'])).decode() == dist['integrity'][5:]
            else:
                identical = dist.get('shasum') == row['sha1']
            if not identical:
                raise ValueError(f'Registry already contains different bytes for {spec}')
            print(f'Skipped existing {spec}', flush=True)
            continue
        try:
            code = json.loads(viewed.stdout)['error']['code']
        except (ValueError, KeyError, TypeError):
            code = None
        if code not in ('E404', 'ETARGET'):
            raise RuntimeError(f'Cannot query {spec}: {viewed.stderr.strip()}')
        subprocess.run(['npm', 'publish', str(root / row['file']), '--ignore-scripts',
                        '--provenance=false', '--tag', 'offline-import', *flags], check=True)
        print(f'Imported {spec}', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('registry', nargs='?', help='Explicit destination registry URL; configure npm login first')
    parser.add_argument('--verify-only', action='store_true', help='Verify all packages without network or publication')
    args = parser.parse_args()
    if not args.verify_only and not args.registry:
        parser.error('specify a registry URL or --verify-only')
    import_registry(Path(__file__).resolve().parent, None if args.verify_only else args.registry)
