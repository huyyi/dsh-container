#!/usr/bin/env python3
"""源配置测试：仅写配置、保留索引、恢复原配置以及非法输入零修改。"""
import importlib.util
from pathlib import Path
import tempfile
import tomllib
import unittest

spec = importlib.util.spec_from_file_location('mirrors', Path(__file__).resolve().parents[1] / 'container/configure-mirrors.py')
mirrors = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mirrors)


class Mirrors(unittest.TestCase):
    def test_configuration_and_restore(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            defaults = root / 'etc/dsh-container/apt-defaults'
            defaults.mkdir(parents=True)
            debian = ('Types: deb\nURIs: http://deb.debian.org/debian\nSuites: bookworm bookworm-updates\n'
                      'Components: main\nSigned-By: /usr/share/keyrings/debian.gpg\n\n'
                      'Types: deb\nURIs: http://security.debian.org/debian-security\nSuites: bookworm-security\n'
                      'Components: main\nSigned-By: /usr/share/keyrings/debian.gpg\n')
            (defaults / 'debian.sources').write_text(debian)
            (defaults / 'nodesource.sources').write_text('Types: deb\nURIs: https://deb.nodesource.com/node_22.x\n')
            (defaults / 'github-cli.list').write_text('deb https://cli.github.com/packages stable main\n')
            lists = root / 'var/lib/apt/lists'
            lists.mkdir(parents=True)
            (lists / 'old-index').write_bytes(b'keep this old index unchanged')
            stamp = (lists / 'old-index').stat().st_mtime_ns
            pip = root / 'etc/pip.conf'
            pip.write_text('[global]\nindex-url = https://old/simple\ntimeout = 42\nextra-index-url = https://public/simple\n')
            uv = root / 'etc/uv/uv.toml'
            uv.parent.mkdir()
            uv.write_text('native-tls = true\n')
            originals = pip.read_bytes(), uv.read_bytes()
            mirrors.configure(root, 'http://apt.internal/repository/debian', 'https://pypi.internal/simple')
            configured = (root / 'etc/apt/sources.list.d/debian.sources').read_text()
            self.assertEqual(configured.count('http://apt.internal/repository/debian'), 2)
            self.assertIn('Suites: bookworm-security', configured)
            self.assertIn('Signed-By: /usr/share/keyrings/debian.gpg', configured)
            self.assertNotIn('https://cli.github.com', (root / 'etc/apt/sources.list.d/github-cli.list').read_text())
            self.assertNotIn('deb.nodesource.com', (root / 'etc/apt/sources.list.d/nodesource.sources').read_text())
            self.assertIn('timeout = 42', pip.read_text())
            self.assertNotIn('extra-index-url', pip.read_text())
            self.assertEqual(tomllib.loads(uv.read_text())['index'][0]['url'], 'https://pypi.internal/simple')
            self.assertNotIn('allow-insecure-host', uv.read_text())
            mirrors.configure(root, 'http://apt.internal/repository/debian', 'http://pypi.internal:8080/simple')
            self.assertIn('trusted-host = pypi.internal:8080', pip.read_text())
            mirrors.configure(root)
            self.assertEqual((pip.read_bytes(), uv.read_bytes()), originals)
            self.assertEqual((root / 'etc/apt/sources.list.d/debian.sources').read_text(), debian)
            self.assertEqual((lists / 'old-index').read_bytes(), b'keep this old index unchanged')
            self.assertEqual((lists / 'old-index').stat().st_mtime_ns, stamp)

    def test_invalid_input_and_no_configuration(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            mirrors.configure(root)
            self.assertEqual(list(root.iterdir()), [])
            for value in ('ftp://mirror/repo', 'https://mirror/repo\ninjected', 'https://mirror:invalid/simple'):
                with self.assertRaises(ValueError):
                    mirrors.configure(root, 'https://apt.internal', value)
                self.assertEqual(list(root.iterdir()), [])
            mirrors.configure(root, pypi='https://pypi.internal/simple')
            mirrors.configure(root)
            self.assertFalse((root / 'etc/pip.conf').exists())
            self.assertFalse((root / 'etc/uv/uv.toml').exists())


if __name__ == '__main__':
    unittest.main()
