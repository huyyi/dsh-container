import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { hash, run } from '../common.mjs';

const directory = path.dirname(fileURLToPath(import.meta.url));
export async function prepare(source, working) {
  const tarball = path.join(working, 'maps.tgz');
  run('curl', ['--fail', '--location', '--retry', '2', 'https://registry.npmjs.org/echarts/-/echarts-4.9.0.tgz', '-o', tarball]);
  if (hash(tarball) !== 'd2bdf8af1b218d3885a518072788a3b7f0c2d3f8925ec8585a36be5ee5add3f2') throw Error('Map SHA-256 mismatch');
  const maps = path.join(working, 'maps');
  fs.mkdirSync(maps);
  run('tar', ['-xzf', tarball, '--no-same-owner', '-C', maps]);
  run('patch', ['--batch', '--forward', '-p1', '-i', path.join(directory, 'genui-intranet.patch')], source);
  run('node', [path.join(directory, 'genui-map-data.mjs'), path.join(maps, 'package'), source]);
}
