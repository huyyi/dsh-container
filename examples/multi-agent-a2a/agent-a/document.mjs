import { readFile, writeFile, access } from 'node:fs/promises'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'

const targets = new Set(['房间布局', '传感器调节'])
export function sections(text) {
  // 围栏内的标题是内容，不能被当作新的文档章节。
  const parts = [{ heading: '', body: '' }]
  let fence
  for (const line of text.match(/[^\n]*\n|[^\n]+$/g) ?? []) {
    const marker = line.match(/^\s*(`{3,}|~{3,})/)
    if (marker) {
      if (!fence) fence = marker[1]
      else if (marker[1][0] === fence[0] && marker[1].length >= fence.length) fence = undefined
    }
    const heading = !fence && !marker && line.match(/^## ([^\r\n]+)\r?\n?$/)
    if (heading) parts.push({ heading: heading[1], line, body: '' })
    else parts.at(-1).body += line
  }
  if (fence) throw new Error('Unclosed Markdown fence')
  return parts
}

export function validate(original, returned) {
  const before = sections(original), after = sections(returned)
  if (before.length !== after.length) throw new Error('Section count changed')
  for (const title of targets) {
    if (before.filter(s => s.heading === title).length !== 1) throw new Error(`Expected exactly one ${title} section`)
  }
  for (let i = 0; i < before.length; i++) {
    const a = before[i], b = after[i]
    if (a.heading !== b.heading || a.line !== b.line) throw new Error('Section heading/order changed')
    if (targets.has(a.heading)) {
      if (a.body.trim()) throw new Error(`Original ${a.heading} must be empty`)
      if (!b.body.trim() || /^(TODO|待补充|待填写)$/i.test(b.body.trim())) throw new Error(`Empty ${a.heading}`)
    } else if (a.body !== b.body) throw new Error(`Protected content changed: ${a.heading || 'title'}`)
  }
}

export async function prepare(directory, templatePath = '/demo/定位方案.template.md') {
  const event = JSON.parse(await readFile(join(directory, 'offline-event.json'), 'utf8'))
  const registry = JSON.parse(await readFile(join(directory, 'warehouses.json'), 'utf8'))
  if (!Object.hasOwn(registry, event.warehouseId)) throw new Error(`Unknown warehouse: ${event.warehouseId}`)
  const mapping = registry[event.warehouseId]
  const fields = { ...event, ...event.lastKnownPosition }
  const template = await readFile(templatePath, 'utf8')
  const document = template.replace(/\{\{(\w+)\}\}/g, (_, key) => {
    const value = fields[key]
    if (value === undefined || /[\r\n]/.test(String(value))) throw new Error(`Invalid field: ${key}`)
    return String(value)
  })
  const paths = ['定位方案.original.md', '定位方案.md'].map(name => join(directory, name))
  for (const path of paths) {
    try { await access(path) } catch (error) { if (error.code === 'ENOENT') continue; throw error }
    throw new Error(`Existing document kept: ${path}; archive it before a new run`)
  }
  for (const path of paths) await writeFile(path, document, { flag: 'wx' })
  console.log(JSON.stringify({ warehouseId: event.warehouseId, ...mapping, document: paths[1] }))
}

export async function accept(directory) {
  const original = await readFile(join(directory, '定位方案.original.md'), 'utf8')
  const returned = await readFile(join(directory, '定位方案.returned.md'), 'utf8')
  validate(original, returned)
  await writeFile(join(directory, '定位方案.md'), returned)
  console.log('Accepted: 定位方案.md; protected text preserved and both sections filled')
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [action, directory = '/home/dsh'] = process.argv.slice(2)
  if (action === 'prepare') await prepare(directory)
  else if (action === 'accept') await accept(directory)
  else throw new Error('Usage: node document.mjs prepare|accept [directory]')
}
