#!/usr/bin/env bash
# dsh-container: 把镜像自带的 dsh 插件登记进数据卷里的 web profile —— 状态是
# "已安装但未启用"(installed, disabled), 用户可在 设置 > 插件管理器 里逐个启用,
# 不需要联网重新下载。
#
# 为什么只写 dependencies + node_modules, 不写 dsh.profile.bundles:
#   - bundles 决定 profile 挂载哪一层(启用), dependencies 只声明"装了什么";
#     镜像的策略是"镜像自带可用、是否启用由用户决定", 因此绝不碰 bundles。
#   - 上游 loadProfileDirectory 只按 bundles 组树, 所以未启用时插件完全不加载;
#     上游 plugin manager 的 listBundles 会把 profile dependencies 里的 bundle
#     包列成 installed:true / enabled:false / removable:true —— 用户在 UI 里
#     一键启用(该操作只把包名追加进 bundles, 全程离线)。
#   - reconcile() 只清理"原本是 profile 依赖、后来被删掉"的 bundle 名
#     (operations.ts), 所以用户启用后的包名不会被插件的下一次管理操作清掉。
#
# 为什么插件代码在 /opt/dsh-plugins 而 profile 里只有软链:
#   /home/dsh 整个是数据卷(可能已存在、也可能是 bind mount), 镜像构建期写进去的
#   内容会被卷遮蔽; 因此真正随镜像升级的是 /opt/dsh-plugins(镜像所有), profile
#   里只登记一条指向它的软链 —— 镜像升级 = 插件升级, 数据卷只多两行元数据。
#
# 幂等与"不抢占":
#   - 软链已指向本镜像的同一目标 → 不动;
#   - 软链指向旧镜像路径(plugins.json 的 root 下) → 刷新到当前路径(镜像升级);
#   - 已存在且属于用户自己的软链/真实目录 → 保留, manifest 里同名依赖也不改写。
# 关闭: DSH_SKIP_PLUGIN_SEED=1(见 docs/deployment.md)。
# 本脚本自身只报告失败; 是否阻断由调用方决定(entrypoint 只告警, dsh web 照常启动)。
set -euo pipefail

log() { echo "[dsh-plugins-seed] $*" >&2; }

if [ "${DSH_SKIP_PLUGIN_SEED:-}" = "1" ]; then
  log "skipped (DSH_SKIP_PLUGIN_SEED=1)"
  exit 0
fi

# 可选参数: 插件清单路径(默认镜像构建期生成的那份; 便于本地/测试指定)。
PLUGINS_JSON="${1:-/etc/dsh-container/plugins.json}"
if [ ! -s "$PLUGINS_JSON" ]; then
  log "no $PLUGINS_JSON; nothing to seed"
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  log "WARNING: jq is missing; cannot read $PLUGINS_JSON"
  exit 0
fi
if ! command -v dsh >/dev/null 2>&1; then
  log "WARNING: dsh is not on PATH; cannot initialize the profile"
  exit 0
fi

# HOME 与其他容器脚本一致地从 passwd 还原(数值 USER 不会自动设置)。
if ! HOME="$(getent passwd "$(id -u)" | cut -d: -f6)"; then
  log "WARNING: cannot resolve HOME for uid $(id -u)"
  exit 0
fi
if [ -z "$HOME" ]; then
  log "WARNING: empty HOME for uid $(id -u)"
  exit 0
fi
export HOME

PROFILE_DIR="${DSH_HOME:-$HOME/.dsh}/profiles/web"
IMAGE_ROOT="$(jq -r '.root // "/opt/dsh-plugins"' "$PLUGINS_JSON")"

# 1. profile 必须存在: 首次启动时用上游自己的初始化路径创建(不联网、不跑 pnpm)。
#    `dsh plugin version-exemptions` 会 mkdir + initProfile(PROFILE_TEMPLATES.web),
#    即 packages/boot/app-boot 的 initProfile: package.json(bundles: dsh-base +
#    dsh-web-app)、cordis.patch.yml、pnpm-workspace.yaml。自己手写这些文件等于
#    复制上游模板, 因此这里让上游来写。失败时不阻断: dsh web 启动时会自己初始化,
#    只是本次登记推迟到下次容器启动(dsh 初始化后仍可正常运行)。
if [ ! -f "$PROFILE_DIR/package.json" ]; then
  if ! dsh plugin --profile web version-exemptions >/dev/null 2>&1; then
    log "WARNING: cannot initialize $PROFILE_DIR via 'dsh plugin'; dsh web will initialize it itself"
    exit 0
  fi
  if [ ! -f "$PROFILE_DIR/package.json" ]; then
    log "WARNING: $PROFILE_DIR/package.json still missing after initialization"
    exit 0
  fi
  log "initialized profile $PROFILE_DIR"
fi

mapfile -t plugin_names < <(jq -r '.plugins[].name' "$PLUGINS_JSON")
if [ "${#plugin_names[@]}" = "0" ]; then
  log "no plugins listed in $PLUGINS_JSON"
  exit 0
fi

linked=0
kept=0
while IFS=$'\t' read -r name path; do
  if [ -z "$name" ] || [ -z "$path" ]; then
    continue
  fi
  if [ ! -f "$path/package.json" ]; then
    log "WARNING: $name: $path/package.json is missing; skipping"
    continue
  fi

  dest="$PROFILE_DIR/node_modules/$name"
  mkdir -p "$(dirname "$dest")"
  owned=0
  if [ -L "$dest" ]; then
    target="$(readlink -f "$dest" 2>/dev/null || true)"
    if [ -n "$target" ] && [ -e "$dest" ] && [ "$target" = "$(readlink -f "$path" 2>/dev/null || true)" ]; then
      owned=1
    elif [ ! -e "$dest" ] || [ "${target#"$IMAGE_ROOT"/}" != "$target" ]; then
      # 断链(旧镜像路径已消失, 例如镜像换过 load 根)或指向旧镜像路径 → 刷新。
      ln -sfn "$path" "$dest"
      log "relinked $name -> $path"
      owned=1
    else
      log "kept existing $dest (not image-owned)"
      kept=$((kept + 1))
    fi
  elif [ -e "$dest" ]; then
    log "kept existing $dest (not image-owned)"
    kept=$((kept + 1))
  else
    ln -s "$path" "$dest"
    log "linked $name -> $path"
    owned=1
  fi
  if [ "$owned" = "1" ]; then
    linked=$((linked + 1))
  fi

  # manifest 的 dependencies: 只补不抢 —— 用户自装的同名依赖(非本镜像路径、且路径
  # 真实存在)保留。用 node 改 JSON(保留其余字段与 2 空格格式, 与上游 saveManifest 一致)。
  node -e '
    const fs = require("node:fs");
    const [file, name, spec, root] = process.argv.slice(1);
    const manifest = JSON.parse(fs.readFileSync(file, "utf8"));
    const dependencies = manifest.dependencies ?? {};
    const current = dependencies[name];
    const fileSpec = current === undefined ? "" : String(current);
    const elsewhere = fileSpec.startsWith("file:") && !fileSpec.startsWith("file:" + root + "/");
    const owned = current === undefined || current === spec
      || fileSpec.startsWith("file:" + root + "/")
      || (elsewhere && !fs.existsSync(fileSpec.slice("file:".length)));
    if (!owned) {
      console.log("kept " + name + " (" + current + ")");
      process.exit(0);
    }
    if (current === spec) {
      console.log("ok " + name + " (already recorded)");
      process.exit(0);
    }
    manifest.dependencies = { ...dependencies, [name]: spec };
    const tmp = file + ".tmp";
    fs.writeFileSync(tmp, JSON.stringify(manifest, undefined, 2) + "\n");
    fs.renameSync(tmp, file);
    console.log("recorded " + name);
  ' "$PROFILE_DIR/package.json" "$name" "file:$path" "$IMAGE_ROOT"
done < <(jq -r '.plugins[] | [.name, .path] | @tsv' "$PLUGINS_JSON")

# 2. 只报告, 不改 bundles —— 启用是用户在插件管理器里的动作。
enabled="$(node -e '
  const fs = require("node:fs");
  const [file, ...names] = process.argv.slice(1);
  const manifest = JSON.parse(fs.readFileSync(file, "utf8"));
  const bundles = manifest.dsh?.profile?.bundles ?? [];
  console.log(bundles.filter(name => names.includes(name)).length);
' "$PROFILE_DIR/package.json" "${plugin_names[@]}")"
log "seeded ${#plugin_names[@]} image plugin(s) into $PROFILE_DIR (linked=$linked kept=$kept already-enabled=$enabled)"
