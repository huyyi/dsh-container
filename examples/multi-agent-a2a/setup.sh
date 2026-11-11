#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

# 首次使用先创建私有目录，避免 Docker 自动创建 root 属主目录。
mkdir -p data
for directory in data/agent-a data/agent-b; do
  if [ ! -d "$directory" ]; then
    mkdir -m 700 "$directory"
  fi
  if [ "$(stat -c %u "$directory")" != 1000 ]; then
    echo "Directory $directory must be owned by container UID 1000; adjust ownership before setup." >&2
    exit 1
  fi
done

# 先启动原镜像，再用官方 CLI 安装插件；依赖保存在各自的宿主机目录中。
docker compose up -d --wait --wait-timeout 180
for agent in agent-b agent-a; do
  docker compose exec -T "$agent" node /demo/init-config.mjs
  docker compose exec -T "$agent" dsh plugin --profile web add @ryubyte/dsh-a2a@0.3.1
  docker compose exec -T "$agent" dsh-restart
  if [ "$agent" = agent-b ]; then
    # 等 B 的协议端点就绪后再启动 A 的出站连接，避免首次发现竞态。
    docker compose exec -T agent-a node --input-type=module -e '
      const url = "http://agent-b:3081/.well-known/agent-card.json";
      let ready = false;
      for (let i = 0; i < 90; i++) {
        try {
          const response = await fetch(url, { signal: AbortSignal.timeout(2000) });
          if (response.ok && (await response.json()).skills?.some(s => s.id === "localization")) { ready = true; break; }
        } catch {}
        await new Promise(resolve => setTimeout(resolve, 1000));
      }
      if (!ready) throw new Error("B Agent Card did not become ready");
    '
  fi
done
echo "Plugin installed. Configure a model in both UIs, then run ./verify.sh."
echo "Agent A: http://127.0.0.1:3381 | Agent B: http://127.0.0.1:3481"
