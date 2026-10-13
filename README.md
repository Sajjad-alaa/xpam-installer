# XPAM Installer

Installer for XPAM, based on the JumpServer v5.0.0 installer. Same commands (`./xpamctl.sh install|start|stop|restart|status|upgrade|...`).

## Install

See **[docs/INSTALL.md](docs/INSTALL.md)** for the full guide. In short:

```bash
git clone -b xpam https://github.com/Sajjad-alaa/xpam-installer.git && cd xpam-installer
mkdir -p /opt/xpam/config && cp config-example.txt /opt/xpam/config/config.txt
echo "XPAM_IMAGE_REGISTRY=ghcr.io/sajjad-alaa/xpam" >> /opt/xpam/config/config.txt
./xpamctl.sh install        # stops once at the image download: docker login ghcr.io, then run it again
./xpamctl.sh start
```

Configuration lives in `/opt/xpam/config`, data in `/data/xpam` (`VOLUME_DIR`). A server installed
before the rename keeps using `/opt/jumpserver/config` and its existing `VOLUME_DIR`.
`XPAM_CONFIG_DIR` overrides the configuration folder.

## XPAM images

These services run XPAM-built images. The Dockerfiles, nginx config, brand kit and the
`build-all.sh` script that builds them are in [`build/`](build/README.md):

| Service | Container | Image | Public path |
|---|---|---|---|
| gateway (front door: ports, TLS, routing) | `xpam_gateway` | `xpam/gateway` | everything enters here |
| core, worker, init-db | `xpam_core`, `xpam_worker` | `xpam/core` | `/core/`, `/api/` |
| web (admin console) | `xpam_web` | `xpam/web` | `/web/` |
| workspace (web terminal) | `xpam_workspace` | `xpam/workspace` | `/workspace/` |
| koko | `xpam_secureconnection` | `xpam/secureconnection` | `/secureconnection/` |
| chen | `xpam_webconnector` | `xpam/webconnector` | `/webconnector/` |
| kael | `xpam_ai` | `xpam/ai` | `/ai/` |

Tags are `${XPAM_VERSION}` (defaults to `XPAM_DEFAULT_VERSION` from `static.env`, `v5.0.0`). XPAM images are **never pulled from
Docker Hub** (the `xpam` namespace there is not ours). Provide them in one of three ways:

1. Build them on the host with `build/build-all.sh` (tags them `xpam/<name>:<version>`).
2. Ship them in the offline package (`scripts/images/<name>:<version>.zst` plus `.sha256`, created by
   `scripts/0_prepare.sh` on a host that has the images).
3. Push them to a registry (`build/push-ghcr.sh`) and set `XPAM_IMAGE_REGISTRY` (for example
   `ghcr.io/<owner>/xpam`) in `config.txt`;
   the installer pulls `<registry>/<name>:<version>` and tags it locally.

Settings in `config.txt`: `XPAM_NAMESPACE` (default `xpam`), `XPAM_VERSION`, `XPAM_IMAGE_REGISTRY`.
Other services (magnus, razor, xrdp, video-worker, nec, panda) keep the upstream JumpServer images.

The admin console, the workspace and each service run in their own container. Stopping or
replacing one of them does not affect the others: the gateway answers that path with a short
"temporarily unavailable" page and picks the container up again within about ten seconds of its
return, without a reload. Only the gateway itself, core and the database are needed by everything.

---

# JumpServer Installer

JumpServer Installer 用来安装和管理 JumpServer。

## 环境依赖
  - Linux x86_64
  - Kernel 大于 4.0

## 安装部署

```bash
# 安装，版本是在 static.env 指定的
$ ./xpamctl.sh install
```

## 管理命令

```
# 启动
$ ./xpamctl.sh start

# 重启
$ ./xpamctl.sh restart

# 关闭, 不包含数据库
$ ./xpamctl.sh stop

# 关闭所有
$ ./xpamctl.sh down

# 备份数据库
$ ./xpamctl.sh backup_db

# 查看日志
$ ./xpamctl.sh tail

# 单独管理企业版 video-worker
$ ./xpamctl.sh video-worker {start|stop|restart|status}

```

`video-worker` 的 Compose service、容器名和配置键统一使用该名称；可通过
`VIDEO_WORKER_ENABLED=0` 禁用本地容器，但不关闭 KoKo 的录像转码提交；需要同时设置
`ENABLE_VIDEO_WORKER=true` 才会让 KoKo 提交录像。容器内默认地址为
`VIDEO_WORKER_HOST=http://video-worker:9000`。如果 worker 独立部署，设置
`VIDEO_WORKER_ENABLED=0`、`ENABLE_VIDEO_WORKER=true`，并将
`VIDEO_WORKER_HOST` 设置为 KoKo 容器可访问的外部地址。安装器仅在
`USE_XPACK=1` 时启用此功能；`USE_XPACK=0` 时会强制关闭 KoKo 的 worker 投递。
`USE_XPACK` 是组件部署模式，不代表许可证校验。旧版本的
`VIDEO_ENABLED`、`VIDEO_ENABLE` 以及 `${VOLUME_DIR}/video` 数据目录会在升级时迁移。

## JDMC（企业版）

JDMC 是企业版组件，需要在 `/opt/jumpserver/config/config.txt` 中设置
`USE_XPACK=1`。它作为宿主机 systemd 服务安装，不加入 Docker Compose。社区版不
下载或安装 JDMC；企业版必须安装 JDMC，不再提供单独的启用或禁用开关。

安装器默认根据 `IMAGE_PULL_PREFIX` 拉取 JDMC artifact 镜像（未配置时使用
`jumpserver/jdmc:${VERSION}`），再按需标记为
`${NAMESPACE:-jumpserver}/jdmc:${VERSION}`，从 `/dist` 提取并执行 JDMC 自带的
`scripts/install.sh` 或 `scripts/upgrade.sh`。
JDMC 与 Core 等自有组件使用相同的拉取和重标记规则，企业版离线包始终包含该镜像。
服务跟随 `xpamctl.sh start/stop/restart/status` 管理，日志可通过
`./xpamctl.sh tail jdmc` 查看。安装器会为 Core 配置
`JDMC_SOCK_PATH=/opt/jumpserver/data/unshare/jdmc.sock`；Core 根据企业版自动启用
JDMC 集成。

安装或升级 JDMC 时，安装器会将当前 `VOLUME_DIR` 传递给 JDMC artifact
脚本。JDMC 据此配置宿主机上的 Core Unix Socket、日志和备份路径，因此可以
继续使用已有的自定义持久化目录，不需要为了升级迁移到 `/data/jumpserver`。
JDMC 启动时也会直接读取 `/opt/jumpserver/config/config.txt` 中的
`VOLUME_DIR`；配置变化后可通过 `systemctl restart jdmc` 重新加载 JDMC 路径。
但修改已安装环境的 `VOLUME_DIR` 不会自动搬迁原有 JDMC 数据，必须先停服务并
显式迁移对应的同级 `jdmc` 目录。

从旧 KOTL 升级时，安装器会识别 `/opt/kotl` 和 `kotl.service`，并调用新
JDMC artifact 的升级脚本完成数据、配置和 systemd 服务迁移。安装或升级成功后会清理旧的
`KOTL_ENABLED`、`JDMC_HOST_ENABLED` 和 `JDMC_ENABLED` 配置，历史禁用值不再生效。
命令行使用 `jdmc` 作为 JDMC 服务目标。
`--skip-jdmc` 仅供 JDMC 发起 JumpServer 重启时避免停止自身，不是组件开关。

## 离线镜像清单

`scripts/gists/image.sh` 是离线镜像选择和重标记规则的唯一来源。调用
`get_offline_image_manifest` 会逐行输出以 Tab 分隔的源镜像和离线包目标镜像：

```text
redis:7.4.10-bookworm<TAB>redis:7.4.10-bookworm
registry.example.com/jumpserver/core:VERSION<TAB>jumpserver/core:VERSION
```

安装器的镜像拉取流程和外部 CI 打包流程都应消费该清单，不应分别维护 Redis、
PostgreSQL、Ansible Executor、OpenBao 或 JDMC 的镜像列表。CI 可以通过
`OFFLINE_IMAGE_SERVICES` 传入逗号或空格分隔的服务范围；未设置时，清单使用安装器
当前配置所启用的服务。

`IMAGE_PULL_PREFIX` 只决定 JumpServer 自有镜像的拉取来源，`NAMESPACE` 只决定这些
镜像拉取后的本地运行名称。Redis、数据库和 OpenBao 等基础镜像保留自己的 registry
和 namespace，不使用 `NAMESPACE`；OpenBao 固定使用 `openbao/openbao:2.6.0`。
`IMAGE_PULL_SCOPE` 默认为 `jumpserver`；设置为 `all` 时，基础镜像也从
`IMAGE_PULL_PREFIX` 拉取，但拉取后仍恢复成各自的固定运行名称。

## 配置文件说明

配置文件将会放在 /opt/jumpserver/config 中

```
[root@localhost config]# tree .
.
├── config.txt       # 主配置文件
├── mysql
│   └── my.cnf       # mysql 配置文件
|── mariadb
|   └── mariadb.cnf  # mariadb 配置文件
├── nginx            # nginx 配置文件
│   ├── cert
│   │   ├── server.crt
│   │   └── server.key
│   ├── lb_http_server.conf
│   └── lb_ssh_server.conf
├── README.md
└── redis
    └── redis.conf  # redis 配置文件

6 directories, 11 files
```

### config.txt 说明

config.txt 文件是环境变量配置文件，会挂载到各个容器中，这样可以不必为 koko、core 单独设置配置文件。

具体可以参考： [JumpServer 参数说明文档](https://docs.jumpserver.org/zh/master/admin-guide/env/)
