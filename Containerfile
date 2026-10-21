# syntax=docker/dockerfile:1
# 继承固定的上游多架构镜像；不重编译 dsh，也不改写上游运行时。
ARG BASE_IMAGE=ghcr.io/niyueee/dsh-container:dsh-v0.2.1-rc.2@sha256:fb8f1865f58b56eb63aad4ab24d0158d48c8823a48e4be54991d05dfec662b6f
FROM ${BASE_IMAGE}
ARG BASE_IMAGE
ARG BUILD_VERSION=local
ARG BUILD_GIT_SHA=unknown
ARG BUILD_GIT_REF=unknown
LABEL org.opencontainers.image.title="DeepSeek Harness with A2A and TUI" \
      org.opencontainers.image.source="https://github.com/huyyi/dsh-container" \
      org.opencontainers.image.description="Pinned upstream dsh container with offline A2A bundle and dsh-tui client" \
      org.opencontainers.image.version="${BUILD_VERSION}" \
      org.opencontainers.image.revision="${BUILD_GIT_SHA}" \
      org.opencontainers.image.ref.name="${BUILD_GIT_REF}" \
      org.opencontainers.image.base.name="${BASE_IMAGE}"

USER root
COPY --chmod=755 container/dsh-plugins-seed.sh /usr/local/bin/dsh-plugins-seed
COPY --chmod=755 container/derived-entrypoint.sh /usr/local/bin/derived-entrypoint
# 保留原有插件清单并加入 A2A；冻结锁文件，禁止自动安装宿主提供的 peer。
COPY container/plugin-payload/ /opt/dsh-plugins/
RUN --mount=type=cache,target=/tmp/dsh-plugin-store \
    cd /opt/dsh-plugins && pnpm install --frozen-lockfile --ignore-scripts --store-dir /tmp/dsh-plugin-store \
    && node -e 'const fs=require("fs"); const root="/opt/dsh-plugins"; const deps=require(root+"/package.json").dependencies; const plugins=Object.keys(deps).map(name=>{const path=root+"/node_modules/"+name; if(!require(path+"/package.json").dsh?.bundle?.patch) throw Error(name+" is not a bundle"); return {name,path};}); fs.writeFileSync("/etc/dsh-container/plugins.json",JSON.stringify({schema:1,root,plugins})+"\n");' \
    && chmod 0444 /etc/dsh-container/plugins.json

# TUI 是独立客户端，单独安装，避免 React 19 与 web 插件的 React 18 冲突。
COPY container/tui-payload/ /opt/dsh-tui/
RUN --mount=type=cache,target=/tmp/dsh-npm-cache \
    cd /opt/dsh-tui && npm ci --omit=dev --ignore-scripts --no-audit --no-fund --cache /tmp/dsh-npm-cache \
    && ln -s /opt/dsh-tui/node_modules/dsh-tui/bin/tui.js /usr/local/bin/dsh-tui

# 保留上游 provenance；派生层元数据单独记录，不冒充重新构建的宿主版本。
RUN jq -cn --arg base "$BASE_IMAGE" --arg revision "$BUILD_GIT_SHA" \
    --arg version "$BUILD_VERSION" \
    '{schema:1,base:$base,revision:$revision,version:$version,a2a:"0.3.1",tui:"0.2.19"}' \
    > /etc/dsh-container/extensions.json
USER 1000
WORKDIR /home/dsh
# 包装入口只登记插件，再交还上游入口；其余运行约定不变。
ENTRYPOINT ["/usr/local/bin/derived-entrypoint"]
