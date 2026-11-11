import test from 'node:test'
import assert from 'node:assert/strict'
import { readFile, writeFile, mkdtemp } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { validate, prepare, accept } from '../agent-a/document.mjs'

const template = new URL('../agent-a/定位方案.template.md', import.meta.url)
const original = await readFile(template, 'utf8')
const filled = original.replace('## 房间布局\n\n', '## 房间布局\n\n矩阵与坐标。\n\n')
  .replace('## 传感器调节\n\n', '## 传感器调节\n\n### 第一轮\n方案和校验结果。\n\n')

test('accepts only filled target sections', () => validate(original, filled))
test('rejects protected changes, missing sections and placeholders', () => {
  for (const value of [original, filled.replace('故障机器人', '其他机器人'),
    filled.replace('## 房间布局', '## 其他章节'), filled.replace('矩阵与坐标。', 'TODO')]) {
    assert.throws(() => validate(original, value))
  }
})
test('headings inside fenced JSON are not document headings', () => {
  validate(original, filled.replace('矩阵与坐标。', '```text\n## quoted heading\n```'))
})
test('prepare, preserve original, accept and refuse overwrite', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'a2a-document-test-'))
  for (const name of ['offline-event.json', 'warehouses.json']) {
    await writeFile(join(dir, name), await readFile(new URL(`../agent-a/${name}`, import.meta.url)))
  }
  await prepare(dir, template)
  const source = await readFile(join(dir, '定位方案.original.md'), 'utf8')
  assert.ok(!source.includes('{{'))
  const response = source.replace('## 房间布局\n\n', '## 房间布局\n布局\n\n')
    .replace('## 传感器调节\n\n', '## 传感器调节\n调节\n\n')
  await writeFile(join(dir, '定位方案.returned.md'), response)
  await accept(dir)
  assert.equal(await readFile(join(dir, '定位方案.md'), 'utf8'), response)
  assert.equal(await readFile(join(dir, '定位方案.original.md'), 'utf8'), source)
  await assert.rejects(prepare(dir, template), /Existing document/)
  await writeFile(join(dir, 'offline-event.json'), JSON.stringify({warehouseId: 'unknown'}))
  await assert.rejects(prepare(dir, template), /Unknown warehouse/)
})
