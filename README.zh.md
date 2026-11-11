# dsh 离线插件

在已有宿主镜像内重新打包指定版本的 dsh 插件，然后在内网手动安装产物目录。
宿主直接使用 [NIyueeE/dsh-container](https://github.com/NIyueeE/dsh-container) 的预构建镜像。

English | [中文](README.zh.md)

## 打包

宿主机仅需 Docker。下载、依赖安装和构建在临时容器中完成，不修改正在使用的 dsh profile。

```sh
bash plugin/offline_repack.sh \
  --image ghcr.io/niyueee/dsh-container:dsh-v0.2.2-rc.2 \
  --output ./offline-export
```

[plugin/plugins.json](plugin/plugins.json) 记录精确版本和 `pack_build_deps`。
初始列表只包含此前已打包的 GenUI 0.16.0 及其内网地图配方，不自动导入旧镜像的预装列表。
`true` 携带锁定源码和开发依赖，供离线重建；`false` 仅携带已构建代码和运行依赖。

每个成功打包的插件生成一个 `插件名-插件版本-dsh-宿主版本` 目录：

```text
offline-export/
  changfenhuang--dsh-genui-0.16.0-dsh-0.2.2-rc.2/
    plugin/
    build/
    offline-manifest.json
    INSTALL.md
    GENUI.md
    genui-intranet.patch
```

作用域包名去掉 `@`，将 `/` 替换为 `--`。只有明确要求时才包含 `build/`。
产物和缓存不入 Git，已有产物不会被覆盖。其他架构或宿主镜像摘要使用不同的输出父目录。

## 内网安装

传入目录和相同宿主镜像。把 `plugin/` 挂载到 `/home/dsh` 外，例如
`/opt/offline-plugins/genui`，并保持挂载。在目标容器内执行：

```sh
dsh plugin --profile web add link:/opt/offline-plugins/genui --offline --ignore-scripts
dsh --profile web --dump-config
dsh-restart
```

dsh 可能直接启用新安装的插件；已有但禁用的插件需要在插件管理器中启用。
携带构建依赖会增加体积和构建时间。外部服务与模型端点仍需单独配置。
复用宿主运行依赖要求使用相同镜像摘要和架构。

## 验证

每次打包都在独立的 `--network none` 容器中换路径只读挂载产物，检查哈希、链接、
离线安装、配置解析和入口导入；要求构建依赖时还会离线重建。测试不发送模型请求。

```sh
bash tests/plugin-offline-repack.sh ghcr.io/niyueee/dsh-container:dsh-v0.2.2-rc.2
```

参见[离线打包](docs/offline-plugins.md)、[开发](docs/development.md)、
[部署](docs/deployment.md)和[安全](docs/security.md)。独立 TUI 客户端不再预置；
此前安装成功不代表它与宿主的 RPC 兼容。

## 许可证

[MIT](LICENSE)
