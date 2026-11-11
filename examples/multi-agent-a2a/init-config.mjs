import { constants } from 'node:fs'
import { copyFile, chmod, mkdir, access, readFile, writeFile, rename } from 'node:fs/promises'

const profile = '/home/dsh/.dsh/profiles/web'
await mkdir(profile, { recursive: true })
try {
  await access('/demo/inbound-AGENTS.md')
  const cwd = `${profile}/.a2a-sessions`
  await mkdir(cwd, { recursive: true })
  const source = await readFile('/demo/inbound-AGENTS.md', 'utf8')
  const target = `${cwd}/AGENTS.md`
  let previous
  try { previous = await readFile(target, 'utf8') } catch (error) {
    if (error.code !== 'ENOENT') throw error
  }
  if (previous !== source) {
    // 角色文件由示例维护；更新前保留用户可能修改过的旧副本。
    // 重命名保留旧文件，也兼容旧挂载遗留的 root 属主文件。
    if (previous !== undefined) await rename(target, `${target}.backup-${Date.now()}`)
    await writeFile(target, source, { flag: 'wx' })
  }
} catch (error) {
  if (error.code !== 'ENOENT') throw error
}
try {
  // 仅初始化，不覆盖已通过插件面板编辑的配置。
  await copyFile('/demo/a2a.json', `${profile}/a2a.json`, constants.COPYFILE_EXCL)
  await chmod(`${profile}/a2a.json`, 0o600)
  console.log('Initialized web/a2a.json')
} catch (error) {
  if (error.code !== 'EEXIST') throw error
  console.log('Kept existing web/a2a.json')
}

// 仅迁移旧示例的能力定义；连接地址、令牌和其他配置不变。
const path = `${profile}/a2a.json`
const active = JSON.parse(await readFile(path, 'utf8'))
const template = JSON.parse(await readFile('/demo/a2a.json', 'utf8'))
if (template.server && active.server?.skills?.some(skill => skill.id === 'acceptance') &&
    !active.server.skills.some(skill => skill.id === 'localization')) {
  await copyFile(path, `${path}.backup-${Date.now()}`)
  active.server.skills = active.server.skills.filter(skill => skill.id !== 'acceptance')
    .concat(template.server.skills)
  for (const key of ['agentName', 'agentDescription', 'agentVersion']) {
    if (template.server[key] !== undefined) active.server[key] = template.server[key]
  }
  await writeFile(path, `${JSON.stringify(active, null, 2)}\n`, { mode: 0o600 })
  console.log('Migrated demo acceptance skill to localization; original config backed up')
}
