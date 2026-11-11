import assert from 'node:assert/strict'
import { readFile, writeFile, mkdtemp } from 'node:fs/promises'
import { prepare, accept } from '/demo/document.mjs'

const config = JSON.parse(await readFile('/home/dsh/.dsh/profiles/web/a2a.json', 'utf8'))
const event = JSON.parse(await readFile('/home/dsh/offline-event.json', 'utf8'))
const registry = JSON.parse(await readFile('/home/dsh/warehouses.json', 'utf8'))
assert.ok(Object.hasOwn(registry, event.warehouseId), 'Unknown warehouse')
const mapping = registry[event.warehouseId]
const peer = config.agents.find(agent => agent.name === mapping.agentName)
assert.ok(peer, 'A must have the selected warehouse peer')
assert.equal(peer.agentCardUrl, mapping.agentCardUrl, 'Registry must match active A2A configuration')
assert.equal(mapping.toolName, `a2a__${peer.name}__localization`)
const cardResponse = await fetch(peer.agentCardUrl)
assert.equal(cardResponse.status, 200)
const card = await cardResponse.json()
assert.ok(card.skills.some(skill => skill.id === 'localization'))
const endpoint = card.supportedInterfaces.find(iface => iface.protocolBinding === 'JSONRPC')?.url
assert.ok(endpoint, 'Agent Card must advertise JSONRPC')
assert.equal(new URL(endpoint).hostname, new URL(peer.agentCardUrl).hostname)
const rpc = (method, params = {}, token = peer.bearerToken) => fetch(endpoint, {
  method: 'POST',
  headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
  body: JSON.stringify({ jsonrpc: '2.0', id: crypto.randomUUID(), method, params }),
  signal: AbortSignal.timeout(300000),
})
assert.equal((await rpc('ListTasks', {}, '')).status, 401)
assert.equal((await rpc('ListTasks', {}, 'incorrect-token')).status, 401)
const list = await rpc('ListTasks')
assert.equal(list.status, 200)
assert.ok((await list.json()).result, 'Authenticated ListTasks must return a result')

// 出站连接是异步建立的，允许启动后的短暂窗口。
let connected = false
for (let attempt = 0; attempt < 30; attempt++) {
  try {
    const snapshot = await (await fetch('http://127.0.0.1:3081/a2a/api')).json()
    connected = snapshot.outbound.some(agent => agent.state === 'connected' && agent.toolCount > 0)
  } catch {}
  if (connected) break
  await new Promise(resolve => setTimeout(resolve, 1000))
}
assert.ok(connected, 'A must register B as an actual model tool')
console.log(`PASS: ${card.name}; Agent Card, auth, ListTasks, A outbound tool registration`)

if (process.argv.includes('--execute')) {
  // 探针使用独立目录，不覆盖 A 的正式交付物。
  const directory = await mkdtemp('/home/dsh/a2a-probe-')
  for (const name of ['offline-event.json', 'warehouses.json']) {
    await writeFile(`${directory}/${name}`, await readFile(`/home/dsh/${name}`))
  }
  await prepare(directory)
  const document = await readFile(`${directory}/定位方案.original.md`, 'utf8')
  // 这是独立的协议执行探针，会调用 B 的模型并计费。
  const response = await rpc('SendMessage', {
    message: {
      messageId: crypto.randomUUID(), role: 'ROLE_USER',
      parts: [{ text: `请根据本地 AGENTS.md 的仓库资料完成以下定位方案。只填充“房间布局”和“传感器调节”章节，其他内容逐字保留。执行几何校验并在章节内给出计划 JSON 和真实校验摘要。返回完整 Markdown，不要加外层代码围栏或额外说明。\n\n${document}` }],
    },
    configuration: { acceptedOutputModes: ['text/plain'], blocking: true },
  })
  assert.equal(response.status, 200)
  const result = await response.json()
  assert.ok(!result.error, JSON.stringify(result.error))
  const task = result.result?.task ?? result.result
  assert.ok(task?.id, 'Expected an A2A Task ID')
  assert.match(task.status?.state ?? '', /COMPLETED$/)
  assert.ok(task.artifacts?.some(artifact => artifact.parts?.some(part => part.text)), 'Expected a text Artifact')
  const returned = task.artifacts.flatMap(artifact => artifact.parts ?? []).map(part => part.text ?? '').join('')
  await writeFile(`${directory}/定位方案.returned.md`, returned)
  await accept(directory)
  console.log(`PASS: B Task ${task.id}; completed document at ${directory}/定位方案.md (geometry still requires review)`)
}
