# 带 A2A 和 TUI 的 dsh 容器

基于 `ghcr.io/niyueee/dsh-container` 的轻量派生镜像。在 [Containerfile](Containerfile)
中固定基础镜像版本和多架构摘要；本仓库不再编译 DeepSeek Harness。

[English](README.md)

## 内置扩展

- `@ryubyte/dsh-a2a@0.3.1`：预装到镜像，登记到 web profile，默认不启用。
- `dsh-tui@0.2.19`：依赖隔离的独立终端客户端。
- 保留原有固定版本的插件载荷。

**已知限制：** TUI 安装及帮助/版本命令可用，但其旧版 `session.list` 协议与基础镜像
的 `session/list` 不兼容（HTTP 404），交互支持尚未完成。
A2A 的发现、认证和离线启用已纳入测试。

## 运行

main 首次成功发布后：

```sh
docker run -d --name dsh -p 127.0.0.1:3081:3081 \
  -v dsh-home:/home/dsh ghcr.io/huyyi/dsh-container:latest
docker exec dsh dsh-tui --version
```

打开 http://127.0.0.1:3081 并配置模型。在设置 → 插件中启用 A2A，然后配置远端或入站服务。
镜像不包含模型凭据。现有 Compose 和多智能体示例保留自己的镜像引用，
不会自动切换到此派生镜像。

## 构建与发布

```sh
docker build -f Containerfile -t dsh-a2a-tui:local .
bash tests/extensions.sh dsh-a2a-tui:local
python3 -m unittest discover -s tests -p 'test_*.py'
python3 tests/validate-docs.py
```

main 每次 push 都构建、测试并发布 amd64/arm64 镜像，包括纯文档更新。
标签由固定的上游版本和提交哈希前七位组成，例如 `dsh-v0.2.1-rc.2-cf05a2f`；
成功发布时同时更新 `latest`。PR 不发布，只有 Markdown/LICENSE 改动时跳过镜像构建；
无法判断 diff 时执行构建。手动触发只验证，不创建 Git tag 或 GitHub Release。

## 文档

- [构建](docs/build.md)
- [部署](docs/deployment.md)
- [安全](docs/security.md)
- [发布](docs/releasing.md)
- [开发](docs/development.md)
- [扩展说明](docs/derived-image.md)

运行时、代理和工具链均继承基础镜像。本仓库只维护扩展打包、登记和验证，
已移除旧源码构建适配代码。
