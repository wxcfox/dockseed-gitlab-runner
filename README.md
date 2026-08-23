# DockSeed GitLab Runner

使用 Docker executor 运行独立的 GitLab Runner。镜像固定为 `gitlab/gitlab-runner:alpine-v19.3.0`，与 GitLab CE 19.3.x 保持相同 major/minor，并支持 Apple Silicon。

## 职责边界

- Runner 与 GitLab 独立启停和升级，不共享 Compose project、网络或 `depends_on`。
- 本项目不要求 Cloudflare，不管理 Tunnel/DNS，也不暴露端口；manager 的连接目标由注册 URL 决定。
- 首次注册要求 GitLab 在线；注册后 Runner 可以先启动并持续重试。Runner 离线不影响 GitLab，未匹配的 CI Job 只会保持 `pending`。

断连参数为 `unhealthy_requests_limit = 3`、`unhealthy_interval = "30s"`，GitLab 恢复后通常会在几十秒内重新连接。

## 前置条件

- Docker Engine 或 Docker Desktop，以及 Docker Compose v2
- Runner manager、Job/helper 容器能访问所需的 GitLab、仓库和 LFS 地址
- 创建 project、group 或 instance runner 的相应 GitLab 权限

本项目主要在 macOS + Docker Desktop 验证。原生 Linux 的本机网络限制见后文。

## 快速开始

### 1. 在 GitLab UI 创建 Runner

优先使用 project runner；同一信任边界内的多个项目使用 group runner。只有集中管理、充分隔离的公共执行集群才适合 instance runner。

- Project：**Settings > CI/CD > Runners > Create project runner**
- Group：**Build > Runners > Create group runner**
- Instance：**Admin > CI/CD > Runners > Create instance runner**

设置明确 tag（例如 `docker-executor`），关闭 **Run untagged**。创建后 GitLab 会显示 Step 1 注册命令和 `glrt-` authentication token。

### 2. 注册

只复制 Step 1 中 `--url` 的值，不要执行包含 `--token` 的完整命令：

```bash
./start.sh register --url https://gitlab.example.com
```

脚本会隐藏读取 token，并通过 stdin 交给一次性容器。token 不进入命令参数或环境文件，注册后只由 Runner 保存在 `runner/config/config.toml`。本项目无需 `.env`，重复注册也不会追加第二个 Runner。

### 3. 启动并验证

```bash
./start.sh up
./start.sh status
./start.sh verify
```

`status` 只显示本地服务状态，`verify` 才检查 GitLab 连接。完整命令运行 `./start.sh help` 查看；连接异常时使用 `./start.sh logs`，`stop` 会保留注册配置和缓存。

## 升级 Runner

Runner 的 major/minor 应与 GitLab 保持一致。先在 GitLab UI 暂停 Runner 并等待现有 Job 结束，再更新 `docker-compose.yml` 中固定的镜像版本，然后执行：

```bash
docker compose pull dockseed-gitlab-runner
./start.sh up
./start.sh verify
```

`./start.sh up` 会使用新镜像重建 Runner manager；宿主机上的 `runner/config/` 与 Docker cache volumes 均会保留，不需要重新注册。验证完成后在 GitLab UI 恢复 Runner，并运行一个实际 CI Job。

## URL 与可选本机链路

`--url` 是 manager 调用 GitLab API、上传下载 artifact 的地址。默认不设置 `clone_url`，Job/helper 使用 GitLab 返回的仓库地址；只有该地址不可达时才增加 `--clone-url`。跨机器或不可信网络应使用 HTTPS。

同机 Docker Desktop 可以只让主仓库 clone/fetch 走本机：

```bash
./start.sh register \
  --url https://gitlab.example.com \
  --clone-url http://host.docker.internal:8929
```

若 API 和 clone/fetch 都不应经过公网入口：

```bash
./start.sh register \
  --url http://host.docker.internal:8929 \
  --clone-url http://host.docker.internal:8929
```

`host.docker.internal` 始终指向 Runner 所在的 Docker 宿主机，不会自动指向另一台 GitLab 服务器。跨机器部署应改用 Runner manager 与 Job/helper 容器都能访问的公网或内网地址。若公网 URL 的唯一入口是 Cloudflare Tunnel，只有 API 和 clone/fetch 都走本机时，Tunnel 离线才不影响这条 CI 链路。

`clone_url` 不改变 manager API、artifact 或 Git LFS endpoint。使用 Git LFS 时需参考 [官方说明](https://docs.gitlab.com/runner/configuration/advanced-configuration/#modify-git-lfs-endpoints) 单独配置。

## 最小 `.gitlab-ci.yml`

```yaml
smoke-test:
  image: alpine:3.22
  tags:
    - docker-executor
  script:
    - echo "dockseed runner is working"
```

`docker-executor` 只是示例；必须替换为 GitLab UI 中实际配置的 tag。本仓库不会创建或修改 tag。

## Docker executor 安全

Runner manager 需要 `/var/run/docker.sock` 来创建 Job 容器。该 socket 具有很高的 Docker daemon 权限，manager 被攻破时可能影响同一 daemon 上的其他容器和数据。

Job 默认不挂载该 socket、保持 `privileged = false`，并只配置 `/cache`。不要手工把 Docker socket 加入 Job 或启用 privileged；只允许可信项目使用 Runner，并为敏感任务使用 protected refs。

默认 Job 不能直接控制宿主 Docker，也不适合直接对宿主 daemon 执行 `docker build`。如需构建镜像，应建立隔离的专用 Runner，配置独立 tag，并优先评估 rootless BuildKit 或 Podman。

## 数据、备份与重新注册

- `runner/config/config.toml`：包含注册 URL 和 token。
- `runner/config/.runner_system_id`：标识当前 Runner manager。
- `/cache`：Runner 管理的 Docker volumes，不在仓库目录中，可丢失并重建。

脚本将配置目录设为 `700`、敏感文件设为 `600`，运行态文件均被 Git 忽略。备份前执行 `./start.sh stop`，再把 `runner/config/` 保存到加密存储；不要在两台机器上同时运行同一份配置。

轮换 token 或重新注册时：

1. 在 GitLab UI 暂停 Runner，并轮换、撤销或删除旧 token。
2. 停止 Runner，加密备份并移走旧的 `config.toml` 和 `.runner_system_id`。
3. 使用新 URL 执行 `register`，在隐藏提示中输入新 token，再执行 `up`、`verify`。

不要因 GitLab 暂时离线而重新注册，也不要运行全局 `docker volume prune` 或 `docker system prune`，以免影响其他项目数据。

## 原生 Linux 限制

当前 DockSeed GitLab 只把 HTTP 发布到宿主机 `127.0.0.1:8929`。原生 Linux 容器通常无法通过 `host.docker.internal` 访问宿主 loopback；本项目不会把 GitLab 改为监听 `0.0.0.0`。

需要本机或内网直连时，可选择受防火墙保护的宿主地址或反向代理，或者把 GitLab、Runner manager 与 Docker executor 的 Job 容器接入受控的共享网络；也可以把 Runner 部署到能直接访问 GitLab 的主机。

## 官方参考

- [官方镜像 `alpine-v19.3.0`](https://hub.docker.com/r/gitlab/gitlab-runner/tags?name=alpine-v19.3.0)
- [Runner authentication token 工作流](https://docs.gitlab.com/ci/runners/new_creation_workflow/)
- [在 Docker 中运行 Runner](https://docs.gitlab.com/runner/install/docker/)
- [高级配置与断连重试](https://docs.gitlab.com/runner/configuration/advanced-configuration/)
- [Runner 安全说明](https://docs.gitlab.com/runner/security/)
