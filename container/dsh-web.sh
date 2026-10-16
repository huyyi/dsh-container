#!/usr/bin/env bash
# dsh web 守护脚本(容器内整个服务栈的监督者):
#   1. 启动 `dsh web`(输出写入日志文件并 tail 镜像到 stdout, 容器日志仍可见),
#      退出/崩溃后自动重新拉起; 配合 `dsh-restart` 可在容器内部重启 dsh web。
#      启动命令挂载镜像自带的容器适配插件 overlay(--patch, launcher flag,
#      必须位于 `web` 之前): 会话 cookie 自举、传输层声明注入、(构建期抽出的)
#      图片路由都在插件内完成, 不再由本脚本 grep 日志 token + curl 交换。
#   2. 把插件写出的会话 cookie(/tmp/dsh-caddy/session-cookie)当状态读取:
#      文件存在且非空 ⇔ 插件当前持有一个可用 cookie; 本脚本只在文件缺失时
#      等待它出现, 之后每轮比较内容, 变了才重建 Caddyfile 并重启 Caddy ——
#      没有 mtime 握手(复用旧 cookie 时插件不写盘, "必须看到一次写入"是错的
#      同步信号)。这个路径是本脚本与插件的共享契约(插件侧 Config.runtimeDir
#      默认值相同; 覆写插件配置就必须同步这里的 RUNTIME_DIR)。dsh 的签名密钥
#      持久化在数据卷
#      凭据库中, cookie 默认 30 天有效、跨进程/跨容器重启有效 —— 插件会复用
#      仍被接受的旧 cookie, 不重复换取。dsh 自身的浏览器围栏
#      (3080 直连无 cookie 仍 401)原样保留, 3081 上的鉴权由 Caddy 承担
#      (basic auth / 网络暴露面)。
#   3. 启动 Caddy 反代监听 0.0.0.0:3081: 把 Host/Origin 改写为回环后转发到
#      127.0.0.1:$DSH_WEB_PORT, 并注入会话 cookie(UI 资源压缩由上游 dsh 的
#      webserver 自带 gzip 承担, Caddy 不再重复压缩); 另外补两条缓存策略:
#      两个索引入口(/ 与 /index.html)no-store(动态启动清单), 内容哈希的
#      /assets/* immutable(dsh 自己不发缓存头, 否则每次导航重下约 475 KiB);
#      运行期崩溃自动重启
#      (配置错误 fail-fast)。DSH_PROXY_USER + DSH_PROXY_PASSWORD 必须成对设置
#      以启用 basic auth, 只设置一个直接退出。
#   4. 可选 SSH 服务端(DSH_SSH_ENABLED, 默认关闭): 以 root 启动
#      /usr/sbin/sshd -f /etc/ssh/sshd_config.dsh(独立完整配置: 仅公钥、禁 root、
#      禁密码/PAM), 主机密钥在数据卷 $HOME/.ssh/host(root 属主, 容器重建不轮换),
#      授权公钥走 ~/.ssh/authorized_keys 或 DSH_SSH_AUTHORIZED_KEYS; 崩溃自动重启,
#      起不来只关闭 SSH 不阻断 web 栈。安全含义见 docs/security.md "SSH access"。
# 附加参数会原样透传给 dsh web, 例如 --port 8080; 容器内默认追加
# --no-open(无浏览器环境), 用户显式传入时不重复。
set -euo pipefail

# 独立执行时也尽量还原 HOME(与 entrypoint 行为一致)。
if ! HOME="$(getent passwd "$(id -u)" | cut -d: -f6)"; then
  echo "[dsh-web] cannot resolve HOME for uid $(id -u)" >&2
  exit 1
fi
if [ -z "$HOME" ]; then
  echo "[dsh-web] empty HOME for uid $(id -u)" >&2
  exit 1
fi
export HOME

# PATH 镜像优先: dsh 必须解析到镜像内的 /usr/local/bin/dsh, 而不是旧数据卷
# 中可能残留的副本; 再拼接用户层自装工具目录(pnpm 全局 bin 在 $PNPM_HOME/bin,
# 与 entrypoint.sh 及 Containerfile 的 ENV PATH 是同一条链路, 必须同步)。
export PATH="/usr/local/bin:$HOME/.local/bin:$HOME/.cargo/bin:${PNPM_HOME:-$HOME/.local/share/pnpm}/bin:$PATH"

# 内部端口: entrypoint 解析 --port 后经 DSH_WEB_PORT 传入(默认 3080)。
# 独立执行(不经 entrypoint)时自身也解析 --port <N>/--port=<N> —— 否则
# dsh web 监听 N 而 Caddy 仍转发到默认端口, 每个请求静默 502。
args_port=""
expect_port=0
for a in "$@"; do
  if [ "$expect_port" = 1 ]; then
    args_port="$a"
    expect_port=0
    continue
  fi
  case "$a" in
    --port) expect_port=1 ;;
    --port=*) args_port="${a#--port=}" ;;
  esac
done
WEB_PORT="${DSH_WEB_PORT:-${args_port:-3080}}"
case "$WEB_PORT" in
  ''|*[!0-9]*) echo "[dsh-web] invalid DSH_WEB_PORT: '$WEB_PORT' (must be a number)" >&2; exit 1 ;;
esac

# 容器/调用方的附加参数(透传给 dsh web)。注意: 函数内的 "$@" 是函数自己的
# 参数而非脚本的, 必须先捕获到数组, 否则 --port 等透传参数会静默丢失。
WEB_ARGS=()
case " $* " in
  *" --no-open "*) WEB_ARGS=("$@") ;;
  *) WEB_ARGS=("$@" "--no-open") ;;
esac

cd "$HOME"

RUNTIME_DIR=/tmp/dsh-caddy
CADDYFILE="$RUNTIME_DIR/Caddyfile"
COOKIE_FILE="$RUNTIME_DIR/session-cookie"
LOG=/tmp/dsh-web.log
SSH_LOG=/tmp/dsh-sshd.log
SSH_PIDFILE=/run/sshd.pid

PIDFILE=/tmp/dsh-web.pid
CHILD_PID=""
CADDY_PID=""
STOPPING=0

# 可选 SSH 服务端(opt-in)。默认关闭: 它是与 3081 代理并列的第二条远程入口,
# 登录后拿到的是一个可免密 sudo 的 shell(等价 root), 因此必须显式开启。
# DSH_SSH_PORT 覆盖端口(sshd 以 root 启动, 22 可用; 配置见 container/sshd_config)。
SSH_ENABLED=0
case "${DSH_SSH_ENABLED:-}" in
  1|true|TRUE|yes|YES|on|ON) SSH_ENABLED=1 ;;
esac
SSH_PORT="${DSH_SSH_PORT:-22}"
case "$SSH_PORT" in
  ''|*[!0-9]*) echo "[dsh-web] invalid DSH_SSH_PORT: '$SSH_PORT' (must be a number)" >&2; SSH_ENABLED=0 ;;
esac
SSH_HOST_KEY_DIR="$HOME/.ssh/host"

# caddy 存活检查: kill -0 对僵尸进程也返回成功(caddy 的父进程是本脚本,
# 会回收子进程), 必须通过 /proc 状态排除 Z。sshd 的监督复用同一判据
# (sshd 由 root 启动、自行 daemonize, 不是本脚本的子进程, 只能靠 pidfile)。
caddy_alive() {
  local st
  st="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
  st="${st#*) }"
  case "$st" in
    Z*) return 1 ;;
  esac
  return 0
}

# --- 可选 sshd(DSH_SSH_ENABLED) ------------------------------------------------
# 配置 /etc/ssh/sshd_config.dsh 是独立完整文件: 不读发行版 sshd_config, 因此
# 发行版默认值不会悄悄改变认证行为(仅公钥、禁 root、禁密码/PAM)。主机密钥在
# 数据卷 $HOME/.ssh/host, 但属主必须是 root: root sshd 拒绝非 root 属主的主机
# 密钥, 而放进卷里是为了容器重建后密钥不轮换(轮换会让所有客户端拒绝连接)。
ssh_pid() {
  cat "$SSH_PIDFILE" 2>/dev/null || true
}

sshd_alive() {
  local pid
  pid="$(ssh_pid)"
  [ -n "$pid" ] || return 1
  caddy_alive "$pid"
}

prepare_sshd() {
  # 特权分离目录在容器里不是开机自建(systemd-tmpfiles 不跑), 必须显式建,
  # 否则 sshd 直接以 "Missing privilege separation directory" 退出。
  if ! sudo -n mkdir -p /run/sshd 2>/dev/null || ! sudo -n chmod 0755 /run/sshd 2>/dev/null; then
    echo "[dsh-web] cannot create /run/sshd (passwordless sudo is required for SSH)" >&2
    return 1
  fi
  # 逐把生成缺失的主机密钥: 只在对应文件缺失时生成, 已存在的密钥绝不重写 ——
  # 重写等于轮换主机密钥, 所有客户端都会拒绝连接。生成/属主/权限三步都显式检查:
  # 本函数在 `if prepare_sshd && ...` 的条件上下文里调用, set -e 被挂起, 隐式失败
  # 会被当成成功。
  if ! sudo -n install -d -m 0700 -o root -g root "$SSH_HOST_KEY_DIR" 2>/dev/null; then
    echo "[dsh-web] cannot prepare $SSH_HOST_KEY_DIR (needs passwordless sudo); SSH stays off" >&2
    return 1
  fi
  local kt bits keyfile
  for kt in ed25519 rsa; do
    keyfile="$SSH_HOST_KEY_DIR/ssh_host_${kt}_key"
    if [ ! -s "$keyfile" ]; then
      echo "[dsh-web] generating SSH host key ($kt) in $SSH_HOST_KEY_DIR" >&2
      if [ "$kt" = "rsa" ]; then
        bits=3072
        sudo -n ssh-keygen -q -t rsa -b "$bits" -N '' -f "$keyfile" \
          || { echo "[dsh-web] ssh-keygen failed for $keyfile" >&2; return 1; }
      else
        sudo -n ssh-keygen -q -t "$kt" -N '' -f "$keyfile" \
          || { echo "[dsh-web] ssh-keygen failed for $keyfile" >&2; return 1; }
      fi
    fi
    # root sshd 只接受 root 属主、0600 的主机密钥(旧卷/旧镜像可能留下别的属主)。
    sudo -n chown root:root "$keyfile" || return 1
    sudo -n chmod 0600 "$keyfile" || return 1
  done
  # 授权公钥: DSH_SSH_AUTHORIZED_KEYS 是最省事的投放方式(公钥不保密, 但会出现在
  # 编排配置与 inspect 里), 幂等去重; 标准位置 ~/.ssh/authorized_keys 同样可用。
  if [ -n "${DSH_SSH_AUTHORIZED_KEYS:-}" ]; then
    mkdir -p "$HOME/.ssh" || return 1
    chmod 700 "$HOME/.ssh" || return 1
    touch "$HOME/.ssh/authorized_keys" || return 1
    chmod 600 "$HOME/.ssh/authorized_keys" || return 1
    local key
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      if ! grep -qxF "$key" "$HOME/.ssh/authorized_keys" 2>/dev/null; then
        printf '%s\n' "$key" >> "$HOME/.ssh/authorized_keys" \
          || { echo "[dsh-web] cannot append DSH_SSH_AUTHORIZED_KEYS to $HOME/.ssh/authorized_keys" >&2; return 1; }
      fi
    done <<< "$DSH_SSH_AUTHORIZED_KEYS"
  fi
  if [ ! -s "$HOME/.ssh/authorized_keys" ]; then
    echo "[dsh-web] WARNING: no ~/.ssh/authorized_keys yet; sshd still starts, but key-only auth means nobody can log in until a key is added" >&2
  fi
  return 0
}

start_sshd() {
  # -o Port 覆盖配置里的 Port(命令行标量选项优先); -E 把 sshd 日志写文件,
  # 排障时 docker exec 查看。sshd 自己 fork 到后台并写 $SSH_PIDFILE, 所以这里
  # 不 tail、不 wait, 由监督循环重启。
  : > "$SSH_LOG"
  if ! sudo -n /usr/sbin/sshd -f /etc/ssh/sshd_config.dsh -E "$SSH_LOG" -o "Port=$SSH_PORT"; then
    echo "[dsh-web] sshd failed to start; log follows:" >&2
    cat "$SSH_LOG" >&2 2>/dev/null || true
    return 1
  fi
  echo "[dsh-web] sshd started on port $SSH_PORT (pid $(ssh_pid)); key-only auth, host keys in $SSH_HOST_KEY_DIR" >&2
  return 0
}

# SC2317: cleanup() 只经下面的 trap 调用, shellcheck 静态看是"不可达", 属误报。
# shellcheck disable=SC2317
cleanup() {
  STOPPING=1
  if [ -n "$CADDY_PID" ]; then
    kill "$CADDY_PID" 2>/dev/null || true
  fi
  # sshd 以 root 运行, 普通 kill 会被 EPERM 拒绝; 免密 sudo 兜底。
  local spid
  spid="$(ssh_pid)"
  if [ -n "$spid" ]; then
    sudo -n kill "$spid" 2>/dev/null || kill "$spid" 2>/dev/null || true
  fi
  if [ -n "$CHILD_PID" ] && kill -0 "$CHILD_PID" 2>/dev/null; then
    kill "$CHILD_PID" 2>/dev/null || true
  fi
  if [ -n "$CHILD_PID" ]; then
    wait "$CHILD_PID" 2>/dev/null || true
  fi
  rm -f "$PIDFILE"
}
trap cleanup TERM INT EXIT

# --- dsh web 启动 -------------------------------------------------------------
# 输出重定向到日志文件再 tail 镜像到 stdout: 容器日志仍能看到 dsh web 的
# 全部输出(含一次性登录 token 与报错)。启动命令用 launcher 根 flag 组合
# `--patch <overlay> --profile web`(注意: `web` 别名会拒绝父级 --patch,
# 见上游 args.ts rejectParentOptions —— 必须用 --profile web 形式)。
start_dsh_web() {
  : > "$LOG"
  dsh --patch /opt/dsh-container-plugin/overlay.yml --profile web "${WEB_ARGS[@]}" >>"$LOG" 2>&1 &
  CHILD_PID=$!
  echo "$CHILD_PID" > "$PIDFILE"
  echo "[dsh-web] dsh web started (pid $CHILD_PID)" >&2
  tail -f --pid="$CHILD_PID" "$LOG" &
}

# --- 会话 cookie(状态文件, 非事件) --------------------------------------------
# 由插件在 dsh 进程内自举(token → cookie, 复用仍有效的旧 cookie)并原子写出;
# 本脚本把 COOKIE_FILE 当状态读取: 存在且非空 ⇔ 插件持有一个可用 cookie。
# 只做两件事:
#   - 文件缺失 → 有界等待插件产出, 等不到 fail-fast(会话自举彻底失败);
#   - 内容变化 → 调用方重建 Caddyfile 并重启 Caddy(插件轮换了 cookie)。
# 不复用旧 cookie 时插件不写盘, 因此绝不能把"文件被写了一次(mtime 前进)"
# 当作就绪信号: 那样复用成功反而会让这里空等 120s 后 exit 1, 容器在重启策略
# 下变成崩溃循环(issue #12)。
wait_for_cookie() {
  for _ in $(seq 1 120); do
    if [ -s "$COOKIE_FILE" ]; then
      echo "[dsh-web] session cookie ready (bootstrapped by the container-adapt plugin)" >&2
      return 0
    fi
    if ! kill -0 "$CHILD_PID" 2>/dev/null; then
      echo "[dsh-web] dsh web exited before the session cookie appeared; last log lines:" >&2
      tail -n 20 "$LOG" >&2 || true
      return 1
    fi
    sleep 1
  done
  echo "[dsh-web] no session cookie from the container-adapt plugin within 120s" >&2
  return 1
}

# dsh 端口就绪门(与 cookie 无关): 容器重启时 cookie 文件已存在, 不先等 dsh
# 监听就拉起 Caddy, 会让反代在 dsh 起来之前对用户返回 502。
wait_for_dsh_port() {
  for _ in $(seq 1 120); do
    if curl -s -o /dev/null "http://127.0.0.1:${WEB_PORT}/" 2>/dev/null; then
      return 0
    fi
    if ! kill -0 "$CHILD_PID" 2>/dev/null; then
      echo "[dsh-web] dsh web exited before listening on 127.0.0.1:${WEB_PORT}; last log lines:" >&2
      tail -n 20 "$LOG" >&2 || true
      return 1
    fi
    sleep 0.5
  done
  echo "[dsh-web] dsh web did not accept connections on 127.0.0.1:${WEB_PORT} within 60s" >&2
  return 1
}

# --- Caddyfile 生成 -----------------------------------------------------------
# header_up Cookie 用整头替换而不是追加: 注入的是内部 authority
# (127.0.0.1:$WEB_PORT)绑定的会话 cookie, 浏览器不可能持有同名 cookie,
# 替换可避免多 Cookie 头拼接在各端解析上的歧义。
generate_caddyfile() {
  local cookie
  cookie="$(cat "$COOKIE_FILE")"
  mkdir -p "$RUNTIME_DIR"
  # 缩进用 tab(caddy fmt 规范), 避免启动时 "Caddyfile input is not formatted" 警告。
  cat > "$CADDYFILE" <<EOF
{
	admin off
	auto_https off
}
:3081 {
	# index.html 是动态启动清单(内联 bundle URL 与 rev): 必须禁缓存。否则镜像
	# 升级后浏览器会用旧前端调用已被移除的端点(旧 /api/events.mux ->
	# 新 /api/remote.mux), 表现为页面能开但事件流全部 502。
	# 上游把索引入口限定为 dist 根与配置的 index path —— 即 / 与 /index.html
	# 两个路径都返回索引, 两个都要禁缓存(只匹配 / 会让从 /index.html 进入的
	# 浏览器缓存旧启动清单)。
	@index path / /index.html
	header @index Cache-Control "no-store"
	# /assets/* 是 Vite 构建的内容哈希产物(assets/index-<hash>.js、vendor-<hash>.css
	# 等)。dsh 自己不给这棵前缀树发任何缓存头(实测无 Cache-Control/ETag/
	# Last-Modified), 浏览器每次导航都要重新下载约 475 KiB(gzip), WAN 上是秒级
	# 开销; 文件名带内容哈希, 无需再验证即可长期缓存。只补这一棵前缀树 ——
	# /plugins/??... 合并包与插件分片由 dsh 自己标了 immutable, 索引入口由
	# @index 禁缓存, 这里都不碰。
	@assets path /assets/*
	header @assets Cache-Control "public, max-age=31536000, immutable"
	reverse_proxy 127.0.0.1:${WEB_PORT} {
		header_up Host 127.0.0.1:${WEB_PORT}
		header_up Origin http://127.0.0.1:${WEB_PORT}
		header_up Cookie "${cookie}"
	}
EOF
  if [ -n "${DSH_PROXY_USER:-}" ] || [ -n "${DSH_PROXY_PASSWORD:-}" ]; then
    # 只设置一个变量时 fail closed: 静默跳过 basic auth 会让用户以为已启用认证。
    if [ -z "${DSH_PROXY_USER:-}" ] || [ -z "${DSH_PROXY_PASSWORD:-}" ]; then
      echo "[dsh-web] DSH_PROXY_USER and DSH_PROXY_PASSWORD must be set together (refusing to start without auth)" >&2
      return 1
    fi
    case "$DSH_PROXY_USER" in
      *[!A-Za-z0-9_.@-]*) echo "[dsh-web] invalid DSH_PROXY_USER: '$DSH_PROXY_USER'" >&2; return 1 ;;
    esac
    # 通过 stdin 哈希, 避免密码出现在 caddy hash-password 的进程 argv 里。
    # caddy 从 stdin 逐行读取并去除末尾换行, 因此 printf 需要补一个 \n。
    # 发行版 caddy 2.6 的 Caddyfile 指令是 basicauth(2.7 起才叫 basic_auth);
    # bcrypt 哈希以 $ 开头即 Modular Crypt Format, 直接写原样, 无需 base64/转义。
    local hash
    if ! hash="$(printf '%s\n' "$DSH_PROXY_PASSWORD" | caddy hash-password 2>/dev/null)"; then
      echo "[dsh-web] failed to hash DSH_PROXY_PASSWORD" >&2
      return 1
    fi
    cat >> "$CADDYFILE" <<EOF
	basicauth {
		$DSH_PROXY_USER $hash
	}
EOF
  fi
  printf '}\n' >> "$CADDYFILE"
  # 文件含 bcrypt 哈希(以及会话 cookie 的注入行), 仅运行时用户可读。
  chmod 600 "$CADDYFILE"
}

# --- Caddy 启动/重启 ------------------------------------------------------------
# 在最多约 5s 内等待代理端口可响应, 进程中途退出或始终无响应均 fail-fast
# (配置/端口错误不静默降级)。
start_caddy() {
  if [ -z "${DSH_PROXY_USER:-}" ] && [ -z "${DSH_PROXY_PASSWORD:-}" ]; then
    echo "[dsh-web] WARNING: the proxy listens on 0.0.0.0:3081 with NO authentication — set DSH_PROXY_USER + DSH_PROXY_PASSWORD before any non-loopback exposure (docs/security.md)" >&2
  fi
  caddy run --config "$CADDYFILE" --adapter caddyfile &
  CADDY_PID=$!
  local ready=0
  for _ in $(seq 1 20); do
    if ! caddy_alive "$CADDY_PID"; then
      echo "[dsh-web] caddy failed to start (config below):" >&2
      cat "$CADDYFILE" >&2
      return 1
    fi
    if curl -sS -o /dev/null "http://127.0.0.1:3081/" 2>/dev/null; then
      ready=1
      break
    fi
    sleep 0.25
  done
  if [ "$ready" != "1" ]; then
    echo "[dsh-web] caddy did not become ready on 127.0.0.1:3081" >&2
    return 1
  fi
}

restart_caddy() {
  if [ -n "$CADDY_PID" ]; then
    kill "$CADDY_PID" 2>/dev/null || true
    wait "$CADDY_PID" 2>/dev/null || true
    CADDY_PID=""
  fi
  start_caddy
}

# --- 栈引导: sshd(可选) → dsh web → 会话 cookie → Caddy -----------------------
# cookie 文件已存在(同一容器重启)时 wait_for_cookie 立即返回 —— 复用路径
# 不会写盘, 所以这里绝不能等"被写一次"。
mkdir -p "$RUNTIME_DIR"

# SSH 先于 web 栈起来: 栈起不来时, SSH 是唯一还能进去排障的入口。启动失败
# (例如没有免密 sudo)只关闭 SSH, 绝不阻断 web 栈 —— 访问权的 fail-closed
# 由"没有 sshd"本身满足。
if [ "$SSH_ENABLED" = "1" ]; then
  if prepare_sshd && start_sshd; then
    :
  else
    echo "[dsh-web] SSH was requested but could not be started; continuing without it" >&2
    SSH_ENABLED=0
  fi
else
  echo "[dsh-web] SSH server disabled (set DSH_SSH_ENABLED=1 to enable; see docs/security.md)" >&2
fi

start_dsh_web
if ! wait_for_cookie; then
  echo "[dsh-web] session bootstrap failed; refusing to serve" >&2
  exit 1
fi
if ! wait_for_dsh_port; then
  echo "[dsh-web] dsh web is not accepting connections; refusing to serve" >&2
  exit 1
fi
generate_caddyfile
if ! start_caddy; then
  exit 1
fi
echo "[dsh-web] caddy started (pid $CADDY_PID); stack ready on 0.0.0.0:3081 -> 127.0.0.1:${WEB_PORT}" >&2

last_cookie="$(cat "$COOKIE_FILE" 2>/dev/null || true)"

# --- 监督循环 -------------------------------------------------------------------
# 单线程轮询(2s): dsh web 退出则重启; cookie 文件缺失则等插件产出(有界, 等不到
# 即退出交给编排层 —— 不静默降级); 插件轮换 cookie(内容变化)才重建 Caddyfile
# 并重启 Caddy —— 复用旧 cookie 时内容不变, Caddy 与浏览器会话全程不中断。
# caddy 崩溃则直接重启。
while [ "$STOPPING" = "0" ]; do
  if ! kill -0 "$CHILD_PID" 2>/dev/null; then
    local_status=0
    set +e
    wait "$CHILD_PID" 2>/dev/null
    local_status=$?
    set -e
    CHILD_PID=""
    if [ "$STOPPING" = "1" ]; then
      break
    fi
    echo "[dsh-web] dsh web exited (status $local_status); restarting in 2s" >&2
    sleep 2
    start_dsh_web
  fi
  if [ ! -s "$COOKIE_FILE" ]; then
    if ! wait_for_cookie; then
      echo "[dsh-web] session bootstrap failed after dsh web restart; giving up" >&2
      exit 1
    fi
  fi
  new_cookie="$(cat "$COOKIE_FILE" 2>/dev/null || true)"
  if [ -n "$new_cookie" ] && [ "$new_cookie" != "$last_cookie" ]; then
    echo "[dsh-web] session cookie changed; regenerating caddy config" >&2
    generate_caddyfile || exit 1
    restart_caddy || exit 1
    last_cookie="$new_cookie"
  fi
  if [ -n "$CADDY_PID" ] && ! caddy_alive "$CADDY_PID"; then
    echo "[dsh-web] caddy exited; restarting" >&2
    restart_caddy || exit 1
  fi
  if [ "$SSH_ENABLED" = "1" ] && ! sshd_alive; then
    echo "[dsh-web] sshd exited; restarting" >&2
    if ! start_sshd; then
      echo "[dsh-web] sshd could not be restarted; SSH stays off until the container restarts" >&2
      SSH_ENABLED=0
    fi
  fi
  sleep 2
done

exit 0
