#!/usr/bin/python3
"""只写入容器内的源配置，不联网、不更新或清理 apt 索引。"""
import base64
import configparser
import io
import json
import os
from pathlib import Path
import re
import tempfile
from urllib.parse import urlsplit


def validate_url(value, name):
    parsed = urlsplit(value)
    _ = parsed.port
    if (parsed.scheme not in ('http', 'https') or not parsed.hostname
            or any(char.isspace() or ord(char) < 32 for char in value)
            or parsed.fragment):
        raise ValueError(f'{name} must be an http(s) repository URL without whitespace or fragments')
    return value.rstrip('/')


def write(path, data, mode=0o644, group=None):
    path.parent.mkdir(parents=True, exist_ok=True)
    # 同目录原子替换，配置不在崩溃时留下半份内容。
    fd, temp = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
        os.chmod(temp, mode)
        if group is not None:
            os.chown(temp, 0, group)
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def configure(root, apt='', pypi=''):
    # 先验证全部输入，再触碰任何配置；错误消息不包含带凭据的 URL。
    apt = validate_url(apt, 'DSH_APT_MIRROR') if apt else ''
    pypi = validate_url(pypi, 'DSH_PYPI_MIRROR') if pypi else ''
    state_file = root / 'var/lib/dsh-container/mirrors.json'
    state = json.loads(state_file.read_text()) if state_file.exists() else {}
    defaults = root / 'etc/dsh-container/apt-defaults'
    if apt or state.get('apt'):
        if not defaults.is_dir():
            raise ValueError('Image apt source defaults are missing')
        state['apt'] = True
        write(state_file, (json.dumps(state) + '\n').encode(), 0o600)
        for original in defaults.iterdir():
            if not original.is_file():
                continue
            data = original.read_bytes()
            if apt:
                text = data.decode()
                if 'deb.nodesource.com' in text or 'cli.github.com' in text:
                    data = b'# Disabled while DSH_APT_MIRROR is configured.\n'
                else:
                    # deb822 和传统 .list 的 URI 都可匹配；其余字段及签名校验保持原样。
                    text = re.sub(r'https?://(?:deb\.debian\.org|security\.debian\.org)/[^\s]+',
                                  lambda _: apt, text)
                    data = text.encode()
            dest = root / 'etc/apt/sources.list.d' / original.name
            if original.name == 'sources.list':
                dest = root / 'etc/apt/sources.list'
            write(dest, data)
        state['apt'] = bool(apt)
    if pypi or state.get('pypi'):
        paths = ('etc/pip.conf', 'etc/uv/uv.toml')
        if not state.get('pypi'):
            # 保存首次接管前的系统配置；取消环境变量后恢复，不删除用户数据卷配置。
            state['python_originals'] = {}
            for name in paths:
                path = root / name
                state['python_originals'][name] = dict(
                    data=base64.b64encode(path.read_bytes()).decode(), mode=path.stat().st_mode & 0o777,
                    uid=path.stat().st_uid, gid=path.stat().st_gid) if path.exists() else None
        state['pypi'] = True
        write(state_file, (json.dumps(state) + '\n').encode(), 0o600)
        if pypi:
            pip = configparser.RawConfigParser()
            original = state['python_originals']['etc/pip.conf']
            if original:
                pip.read_string(base64.b64decode(original['data']).decode())
            if not pip.has_section('global'):
                pip.add_section('global')
            pip.set('global', 'index-url', pypi)
            # 移除系统层的额外索引，避免内网配置仍回退到其他服务器。
            pip.remove_option('global', 'extra-index-url')
            if urlsplit(pypi).scheme == 'http':
                host = urlsplit(pypi).hostname
                if ':' in host:
                    host = '[' + host + ']'
                if urlsplit(pypi).port:
                    host += ':' + str(urlsplit(pypi).port)
                pip.set('global', 'trusted-host', host)
            output = io.StringIO()
            pip.write(output)
            write(root / paths[0], output.getvalue().encode(), 0o640, 1000 if root == Path('/') else None)
            # 系统 uv 文件由环境变量管理；原文件已保存，取消变量时完整恢复。
            uv = '[[index]]\nname = "dsh-internal"\nurl = ' + json.dumps(pypi) + '\ndefault = true\n'
            write(root / paths[1], uv.encode(), 0o640, 1000 if root == Path('/') else None)
        else:
            for name in paths:
                path = root / name
                original = state['python_originals'][name]
                if original:
                    write(path, base64.b64decode(original['data']), original['mode'])
                    if root == Path('/'):
                        os.chown(path, original['uid'], original['gid'])
                else:
                    path.unlink(missing_ok=True)
            state.pop('python_originals', None)
        state['pypi'] = bool(pypi)
    if state:
        write(state_file, (json.dumps(state) + '\n').encode(), 0o600)


if __name__ == '__main__':
    try:
        configure(Path('/'), os.environ.get('DSH_APT_MIRROR', ''), os.environ.get('DSH_PYPI_MIRROR', ''))
    except (ValueError, OSError, configparser.Error):
        raise SystemExit('[entrypoint] cannot configure mirrors; check repository URL format and configuration file permissions')
