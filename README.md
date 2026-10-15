# DockSeed GitLab Runner

使用 Docker Compose 运行独立的 GitLab Runner manager，通过 Docker executor 执行任务。一个 manager 可以管理多个 Runner，与 GitLab 分开部署、独立启停和升级。

## 配置与数据

- `.env`：Runner manager 镜像仓库、版本和全局 Job 并发数；从 `.env.example` 复制且不提交。
- `docker-compose.override.yml`：可选，本机专用的 Compose 配置（如为 Runner manager 添加 `extra_hosts`），存在时自动叠加且不提交；不要直接修改 `docker-compose.yml`。Job 容器的配置在 `config.toml` 中修改。
- `runner/config/`：注册信息、token、system ID，以及记录哪些 Runner 以 privileged 注册的 `.privileged_runners`；运行时生成且不会提交到 Git。
- `/cache`：Runner 管理的 Docker cache volumes。

更换镜像只会重建 Runner manager 容器，不会删除注册配置或缓存。

## 首次使用

支持 macOS 的 Docker Desktop 和 Linux 的 Docker Engine（Linux 容器）。需要支持 `docker compose config --environment` 的 Compose 插件，`register` 和 `up` 会检查此能力。当前用户需要能访问 Docker daemon 并读写 `runner/config/`。

确保 Runner manager 和 Job 容器可以访问 GitLab 与代码仓库，宿主 Docker 能拉取所需镜像；所选镜像也须支持宿主架构。

复制配置模板并按需修改 `.env`：

```bash
cp .env.example .env
chmod 600 .env
```

`RUNNER_CONCURRENT` 必须为正整数，表示 Runner manager 同时执行的最大 Job 数，所有 Runner 共用这个额度。提高并发数前，请确认宿主机资源充足。

默认从 Docker Hub 拉取 `gitlab/gitlab-runner:alpine-v<版本>`。需要更换来源时，在 `.env` 设置 `GITLAB_RUNNER_IMAGE_REPOSITORY`，例如 GitLab 官方仓库 `registry.gitlab.com/gitlab-org/gitlab-runner`，无需修改 Compose 文件。该项只改变 manager 镜像，不改变 Job、service 或 helper 镜像来源。

### 1. 在 GitLab UI 创建 Runner 并打好标签

在 GitLab 的 project、group 或 instance 的 Runners 页面创建 Runner。一台机器上常见的是两个：

| 用途 | 建议 tag | UI 中的选项 |
| --- | --- | --- |
| 普通 Job | `shared-docker` | 默认即可 |
| Docker-in-Docker 构建镜像 | `container-build` | 不勾选「Run untagged jobs」，只运行带标签的 Job |

表中的 tag 只是示例，由使用者自定，需与 `.gitlab-ci.yml` 里的 `tags` 一致。注册时使用 GitLab UI 显示的 URL 和对应 Runner 的 `glrt-` authentication token。

### 2. 逐个注册

```bash
./start.sh register --url https://gitlab.example.com --name shared-docker
./start.sh register --url https://gitlab.example.com --name container-build --privileged
```

`register` 会隐藏读取 token，然后由 `gitlab-runner register` 向 `config.toml` 追加一个 `[[runners]]` 段，已有段和全局 `concurrent` 不受影响。`--name` 必填且不能与已有段重名，重名时请先 `unregister`。只注册一个普通 Runner 也可以，第二个随时再加。

默认 Job 镜像为 `alpine:3.22`。注册时可通过 `--docker-image <镜像地址>` 为该 Runner 指定其他默认镜像，仅在 CI 未设置 `image` 时使用；不会修改已有 Runner 的配置或 CI 中的 `services`。

`--privileged` 让该 Runner 的 Job 容器以 privileged 模式运行，等同于宿主机 root，只给可信项目，并通过 tag 与「只运行带标签的 Job」限制范围；默认关闭。该 Runner 额外挂载 `/certs/client`，供 Job 与 `docker:dind` 服务共享 TLS 证书。

### 3. 启动并验证

```bash
./start.sh up
./start.sh verify
```

`up`、`verify`、`status`、`logs`、`stop` 都作用于 manager 管理的全部 Runner。其他命令和可选参数运行 `./start.sh help` 查看。

`verify` 只检查与 GitLab 的连接和注册。要确认可以执行任务，还需在使用该 Runner 的项目中运行一次 CI，验证代码克隆、镜像拉取及实际构建，见下一节。

## 在项目中使用 Runner

Runner 主动向 GitLab 拉取 Job，项目接入只需在 GitLab 中配置，不需要登录 Runner 所在的机器。Job 需要的凭据（如部署密钥）通过 CI/CD Variables 提供，不依赖宿主机上的账号或文件。

1. 确认项目可用该 Runner：group Runner 对该 group 及其子 group 的项目生效，instance Runner 对全部项目生效，需在项目 Settings → CI/CD → Runners 中保持对应开关开启；project Runner 需在项目中单独启用。
2. 在 `.gitlab-ci.yml` 中用 `tags` 选中 Runner，值须与 Runner 的标签一致。以上文示例标签为例：

   ```yaml
   test:
     tags: [shared-docker]
     script:
       - echo "runs in the Runner's default image"

   build-image:
     image: docker:cli
     services: [docker:dind]
     tags: [container-build]
     variables:
       DOCKER_TLS_CERTDIR: "/certs"
     script:
       - docker build -t "example:$CI_COMMIT_SHORT_SHA" .
   ```

   不带 `tags` 的 Job 只会被勾选了「Run untagged jobs」的 Runner 执行，否则会一直 pending。
3. 推送后查看 Job 日志，确认由预期的 Runner 执行，且代码克隆、镜像拉取和构建均成功。

## 注销 Runner

```bash
./start.sh unregister --name container-build
```

`unregister` 调用 `gitlab-runner unregister` 注销该 Runner 在本机的 manager，成功后从 `config.toml` 删除对应段，其他段不动。GitLab 必须在线；如果 GitLab 侧已经删除了该 Runner 导致注销失败，请手动从 `config.toml` 删除对应的 `[[runners]]` 段。使用本项目的 `glrt-` 工作流时，GitLab UI 中的 Runner 记录仍然保留，如不再需要需在 UI 中删除。

## 调整版本或并发数

修改 `.env` 中的镜像版本或 `RUNNER_CONCURRENT`，然后启动：

```bash
./start.sh up
```

缺少目标镜像时 Docker 会自动拉取。重建容器时，旧 Runner 会停止接收新 Job，并等待当前 Job 完成，最长等待 1 小时。升级通常不需要重新注册；如需回退，把版本改回原值并再次运行 `./start.sh up`。

## 安全边界

Runner manager 挂载了 `/var/run/docker.sock`，因此只应服务可信项目。每次 `up` 和 `verify` 前都会逐段校验 `config.toml`：

- 至少有一个 `[[runners]]` 段，且每段的 executor 都是 `docker`；
- 任何段都不得为 Job 挂载 `/var/run/docker.sock`；
- `privileged = true` 只允许出现在注册时明确 `--privileged` 的段，这些段的名字记录在 `runner/config/.privileged_runners` 中。手改 `config.toml` 给其他 Runner 打开 privileged 会被拒绝启动。

普通 Runner 的 Job 默认不挂载 Docker socket、不启用 privileged，并仅使用 `/cache`。

tag 只用于选择 Runner，不限制使用者：可用该 Runner 的项目都能在 `.gitlab-ci.yml` 中写上它的 tag。privileged Runner 注册在 group 或 instance 级别时，范围内能修改 CI 配置的成员都能借此获得宿主机 root 权限。需要收紧时，将其改为只分配给可信项目的 project Runner。在 Runner 设置中勾选「Protected」可进一步限定只执行 protected 分支和 tag 的 Job，但它不限制项目范围：各项目的 Maintainer 自行管理保护规则，因此仍需信任所有可用该 Runner 的项目。

不要提交或删除 `runner/config/`；GitLab 暂时离线时也无需重新注册。

## 官方参考

- [GitLab Runner](https://docs.gitlab.com/runner/)
- [在 Docker 中运行 Runner](https://docs.gitlab.com/runner/install/docker/)
- [Runner 命令与注销行为](https://docs.gitlab.com/runner/commands/#gitlab-runner-unregister)
- [用 Docker executor 构建镜像（Docker-in-Docker）](https://docs.gitlab.com/ci/docker/using_docker_build/)
- [Runner 安全说明](https://docs.gitlab.com/runner/security/)
