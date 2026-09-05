# DockSeed GitLab Runner

使用 Docker Compose 运行独立的 self-managed GitLab Runner manager，执行器为 Docker。一个 manager 管理同一份 `config.toml` 里的多个 `[[runners]]`，常见组合是一个普通 Runner 加一个用于 Docker-in-Docker 构建镜像的 privileged Runner。Runner 与 GitLab 分开部署，可以独立启停和升级。

## 配置与数据

- `.env`：Runner 镜像版本和全局 Job 并发数；从 `.env.example` 复制且不提交。`RUNNER_CONCURRENT` 是所有 Runner 合计的并发上限，不是每个 Runner 各自的上限。
- `runner/config/`：注册信息、token、system ID，以及记录哪些 Runner 以 privileged 注册的 `.privileged_runners`；运行时生成且不会提交到 Git。
- `/cache`：Runner 管理的 Docker cache volumes。

更换镜像只会重建 Runner manager 容器，不会删除注册配置或缓存。

## 首次使用

需要 Docker Compose v2，并确保 Runner manager 和 Job 容器可以访问 GitLab 与代码仓库。

复制配置模板并按需修改 `.env`：

```bash
cp .env.example .env
chmod 600 .env
```

`RUNNER_CONCURRENT` 必须为正整数，表示 Runner manager 同时执行的最大 Job 数，所有 Runner 共用这个额度。提高并发数前，请确认宿主机资源充足。

### 1. 在 GitLab UI 创建 Runner 并打好标签

在 GitLab 的 project、group 或 instance 的 Runners 页面创建 Runner。一台机器上常见的是两个：

| 用途 | 建议 tag | UI 中的选项 | 本地注册命令 |
| --- | --- | --- | --- |
| 普通 Job | `shared-docker` | 默认即可 | `./start.sh register --url <URL> --name shared-docker` |
| Docker-in-Docker 构建镜像 | `container-build` | 不勾选「Run untagged jobs」，只运行带标签的 Job | `./start.sh register --url <URL> --name container-build --privileged` |

表中的 tag 只是示例，由使用者自定，需与 `.gitlab-ci.yml` 里的 `tags` 一致。每个 Runner 创建后 UI 会显示 Step 1 的 URL 和一个 `glrt-` authentication token，一个 Runner 对应一个 token。

### 2. 逐个注册

```bash
./start.sh register --url https://gitlab.example.com --name shared-docker
./start.sh register --url https://gitlab.example.com --name container-build --privileged
```

`register` 会隐藏读取 token，然后由 `gitlab-runner register` 向 `config.toml` 追加一个 `[[runners]]` 段，已有段和全局 `concurrent` 不受影响。`--name` 必填且不能与已有段重名，重名时请先 `unregister`。只注册一个普通 Runner 也可以，第二个随时再加。

`--privileged` 让该 Runner 的 Job 容器以 privileged 模式运行，等同于宿主机 root，只给可信项目，并通过 tag 与「只运行带标签的 Job」限制范围；默认关闭。该 Runner 额外挂载 `/certs/client`，为 `docker:dind` 服务共享 TLS 证书预留，Job 不启用 TLS 时该挂载无副作用。

### 3. 启动并验证

```bash
./start.sh up
./start.sh verify
```

`up`、`verify`、`status`、`logs`、`stop` 都作用于 manager 管理的全部 Runner。其他命令和可选参数运行 `./start.sh help` 查看。

构建镜像的 Job 在 `.gitlab-ci.yml` 中用 `tags` 选中 privileged Runner，并使用 `image: docker:cli` 加 `services: [docker:dind]` 的标准 Docker-in-Docker 写法。

## 注销 Runner

```bash
./start.sh unregister --name container-build
```

`unregister` 调用 `gitlab-runner unregister` 从 GitLab 侧注销该 Runner，成功后从 `config.toml` 删除对应段，其他段不动。GitLab 必须在线；如果 GitLab 侧已经删除了该 Runner 导致注销失败，请手动从 `config.toml` 删除对应的 `[[runners]]` 段。GitLab UI 中的 Runner 记录如不再需要，请在 UI 中删除。

## 从单 Runner 配置升级

之前用旧版本注册的单 Runner 配置无需任何改动：目录布局不变，不需要重新注册，直接 `./start.sh up` 即可。需要构建镜像时再追加一个 `--privileged` Runner。

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

不要提交或删除 `runner/config/`；GitLab 暂时离线时也无需重新注册。

## 官方参考

- [GitLab Runner](https://docs.gitlab.com/runner/)
- [在 Docker 中运行 Runner](https://docs.gitlab.com/runner/install/docker/)
- [用 Docker executor 构建镜像（Docker-in-Docker）](https://docs.gitlab.com/ci/docker/using_docker_build/)
- [Runner 安全说明](https://docs.gitlab.com/runner/security/)
