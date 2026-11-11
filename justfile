# 插件打包和验证；不构建宿主镜像。
image := "ghcr.io/niyueee/dsh-container:dsh-v0.2.2-rc.2"

pack host=image:
    bash plugin/offline_repack.sh --image {{host}}

test host=image:
    bash tests/plugin-offline-repack.sh {{host}}

lint:
    bash tests/lint.sh
