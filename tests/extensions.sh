#!/usr/bin/env bash
# 派生镜像检查：独立临时容器，离线启用 A2A，不访问模型供应商。
# shellcheck disable=SC2016
set -euo pipefail
DOCKER="${DOCKER:-docker}"
image="${1:?image required}"
cid=""
trap 'if [ -n "$cid" ]; then "$DOCKER" rm -f "$cid" >/dev/null; fi' EXIT
cid="$("$DOCKER" run -d "$image")"
for _ in $(seq 1 90); do
  if [ "$("$DOCKER" inspect -f '{{.State.Health.Status}}' "$cid")" = healthy ]; then break; fi
  sleep 2
done
test "$("$DOCKER" inspect -f '{{.State.Health.Status}}' "$cid")" = healthy
"$DOCKER" exec "$cid" node --input-type=module -e '
import assert from "node:assert/strict";
const proxy="http://127.0.0.1:3081";
assert.equal((await fetch(proxy)).status,200);
assert.equal((await fetch(proxy+"/api/settings/describe",{method:"POST",headers:{"Content-Type":"application/json"},body:"{}"})).status,200);
assert.equal((await fetch("http://127.0.0.1:3080/api/settings/describe",{method:"POST",headers:{"Content-Type":"application/json"},body:"{}"})).status,401);
'
"$DOCKER" exec "$cid" node -e '
const fs=require("fs"),assert=require("assert/strict");
const p="/home/dsh/.dsh/profiles/web/package.json";
const m=JSON.parse(fs.readFileSync(p));
const name="@ryubyte/dsh-a2a";
assert.equal(require("/opt/dsh-plugins/node_modules/"+name+"/package.json").version,"0.3.1");
assert.equal(m.dependencies[name],"file:/opt/dsh-plugins/node_modules/"+name);
assert.ok(!m.dsh.profile.bundles.includes(name));
assert.equal(require("/opt/dsh-tui/node_modules/dsh-tui/package.json").version,"0.2.19");
m.dsh.profile.bundles.push(name);
fs.writeFileSync(p,JSON.stringify(m));
fs.writeFileSync("/home/dsh/.dsh/profiles/web/a2a.json",JSON.stringify({mode:"server",server:{enabled:true,baseUrl:"http://127.0.0.1:3081",agentName:"CI A2A",authToken:"ci-only-token",skills:[{id:"probe",name:"Probe",description:"CI discovery only",tags:["test"]}]}}));
'
"$DOCKER" exec "$cid" dsh-restart
"$DOCKER" exec "$cid" node --input-type=module -e '
let ok=false;
for(let i=0;i<60;i++) {
  try {const r=await fetch("http://127.0.0.1:3081/.well-known/agent-card.json",{signal:AbortSignal.timeout(2000)}); const c=await r.json(); if(c.skills.some(s=>s.id==="probe")){ok=true;break;}}catch{}
  await new Promise(r=>setTimeout(r,1000));
}
if(!ok)throw Error("A2A bundle did not load");
const response=await fetch("http://127.0.0.1:3081/a2a",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({jsonrpc:"2.0",id:"test",method:"ListTasks",params:{}})});
if(response.status!==401)throw Error("Unauthenticated A2A was not rejected");
const authorized=await fetch("http://127.0.0.1:3081/a2a",{method:"POST",headers:{"Content-Type":"application/json",Authorization:"Bearer ci-only-token"},body:JSON.stringify({jsonrpc:"2.0",id:"test-auth",method:"ListTasks",params:{}})});
if(authorized.status!==200 || !(await authorized.json()).result)throw Error("Authenticated A2A task listing failed");
'
# 只验证 CLI 可启动；已知该版本的点号 RPC 与当前宿主斜杠 RPC 不兼容。
test "$("$DOCKER" exec "$cid" dsh-tui --version)" = 0.2.19
"$DOCKER" exec "$cid" dsh-tui --help >/dev/null
echo 'PASS: runtime auth, A2A offline enable/discovery, TUI installation and CLI startup'
echo 'NOTICE: dsh-tui 0.2.19 session.list is incompatible with this host session/list; interactive use is NOT verified'
