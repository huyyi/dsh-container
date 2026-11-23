#!/usr/bin/env python3
"""校验并在断网环境中安装插件。"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parent
manifest = json.loads((root / 'plugins.json').read_text())
if len(sys.argv) != 2:
    sys.exit('Usage: bash install.sh <existing-profile>')
arch = {'x86_64': 'amd64', 'aarch64': 'arm64'}.get(os.uname().machine)
if f'{sys.version_info.major}.{sys.version_info.minor}' != manifest['python']:
    sys.exit('Plugin archive Python version does not match this container')
if arch != manifest['architecture']:
    sys.exit('Plugin archive architecture does not match this container')
version = json.loads(Path('/opt/deepseek-harness/apps/cli/package.json').read_text())['version']
if version != manifest['dsh']:
    sys.exit(f"Archive requires dsh {manifest['dsh']}; running {version}")
for name, digest in json.loads((root / 'SHA256SUMS.json').read_text()).items():
    path = (root / name).resolve()
    if not path.is_relative_to(root) or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
        sys.exit(f'Checksum mismatch: {name}')
env = dict(os.environ, npm_config_offline='true', npm_config_ignore_scripts='true')
for plugin in manifest['plugins']:
    if plugin['status'] == 'skipped':
        print(f"Skipping {plugin['spec']}: {plugin['reason']}", flush=True)
        continue
    folder = (root / plugin['path']).resolve()
    if not folder.is_relative_to(root):
        sys.exit('Invalid plugin path')
    if plugin['requirements']:
        venv = folder / '.venv'
        subprocess.run(['uv', 'venv', '--offline', '--python', '/usr/bin/python3', str(venv)], check=True)
        args = ['uv', 'pip', 'install', '--python', str(venv / 'bin/python'), '--no-index', '--find-links', str(folder / 'wheelhouse')]
        for req in plugin['requirements']:
            args.extend(['-r', str(folder / req)])
        subprocess.run(args, check=True)
        if plugin['name'] == 'dsh-office-kit':
            config = Path.home() / '.dsh/office/config.json'
            config.parent.mkdir(parents=True, exist_ok=True)
            data = json.loads(config.read_text()) if config.exists() else {}
            data['python'] = str(venv / 'bin/python')
            config.write_text(json.dumps(data, indent=2) + '\n')
    subprocess.run(['dsh', '--profile', sys.argv[1], 'plugin', 'add', str(folder)], env=env, check=True)
