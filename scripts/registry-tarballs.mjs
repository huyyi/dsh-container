#!/usr/bin/env node
// 直接按完整性摘要读取 npm 内容缓存，保留原始 tarball 字节；缓存缺失时重新取原包。
import { createHash } from 'node:crypto'
import { execFile } from 'node:child_process'
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { createRequire } from 'node:module'
import { dirname, join } from 'node:path'
import { tmpdir } from 'node:os'
import { promisify } from 'node:util'

const [input, output, npmHome, cache] = process.argv.slice(2)
const npmRequire = createRequire(join(npmHome, 'package.json'))
let cacache
try { cacache = npmRequire('cacache') } catch { /* npm 内部布局变化时走标准 npm pack。 */ }
const exec = promisify(execFile)
const requests = JSON.parse(await readFile(input, 'utf8'))

function matches(bytes, integrity) {
  return integrity.split(/\s+/).some(token => {
    const at = token.indexOf('-')
    const algorithm = token.slice(0, at)
    return ['sha1', 'sha256', 'sha384', 'sha512'].includes(algorithm)
      && createHash(algorithm).update(bytes).digest('base64') === token.slice(at + 1)
  })
}

async function collect(row) {
  let bytes
  if (cacache) {
    try { bytes = await cacache.get.byDigest(join(cache, '_cacache'), row.integrity) } catch { /* 缺失或损坏后按原来源重取。 */ }
  }
  const integrities = row.integrities ?? [row.integrity]
  if (!bytes || !integrities.every(integrity => matches(bytes, integrity))) {
    const temp = await mkdtemp(join(tmpdir(), 'dsh-registry-'))
    try {
      const { stdout } = await exec('npm', ['pack', row.source, '--json', '--ignore-scripts'],
        { cwd: temp, maxBuffer: 8 * 1024 * 1024 })
      const packed = JSON.parse(stdout)[0]
      bytes = await readFile(join(temp, packed.filename))
    } finally { await rm(temp, { recursive: true, force: true }) }
  }
  if (!integrities.every(integrity => matches(bytes, integrity))) throw new Error(`Registry integrity mismatch: ${row.name}@${row.version}`)
  const file = join(output, row.file)
  await mkdir(dirname(file), { recursive: true })
  await writeFile(file, bytes)
  return { ...row, size: bytes.length,
    sha256: createHash('sha256').update(bytes).digest('hex'),
    sha1: createHash('sha1').update(bytes).digest('hex'),
    sha512: 'sha512-' + createHash('sha512').update(bytes).digest('base64') }
}

// 限制并发，避免同时把大量原生包读入内存。
const results = new Array(requests.length)
let next = 0
await Promise.all(Array.from({ length: 4 }, async () => {
  while (next < requests.length) {
    const at = next++
    results[at] = await collect(requests[at])
  }
}))
await writeFile(join(output, 'packages.json'), JSON.stringify({ packages: results }, null, 2) + '\n')
