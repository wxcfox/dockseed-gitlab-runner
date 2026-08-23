# DockSeed GitLab Runner

使用 Docker Compose 运行独立的 self-managed GitLab Runner，执行器为 Docker。Runner 与 GitLab 分开部署，可以独立启停和升级。

## 配置与数据

- `version.env`：Runner 镜像版本，纳入版本控制。
- `runner/config/`：注册信息、token 和 system ID，运行时生成且不会提交到 Git。
- `/cache`：Runner 管理的 Docker cache volumes。

更换镜像只会重建 Runner manager 容器，不会删除注册配置或缓存。

## 首次使用

需要 Docker Compose v2，并确保 Runner manager 和 Job 容器可以访问 GitLab 与代码仓库。

先在 GitLab 创建 project、group 或 instance Runner，设置明确的 tag，并取得 `glrt-` authentication token，然后执行：

```bash
./start.sh register --url https://gitlab.example.com
./start.sh up
./start.sh verify
```

`register` 会隐藏读取 token；已有注册配置时不会覆盖或追加 Runner。其他命令和可选参数运行 `./start.sh help` 查看。

## 升级与回退

修改 `version.env` 中的版本，然后启动：

```bash
./start.sh up
```

缺少目标镜像时 Docker 会自动拉取。重建容器时，旧 Runner 会停止接收新 Job，并等待当前 Job 完成，最长等待 1 小时。升级通常不需要重新注册；如需回退，把版本改回原值并再次运行 `./start.sh up`。

## 安全边界

Runner manager 挂载了 `/var/run/docker.sock`，因此只应服务可信项目。Job 默认不挂载 Docker socket、不启用 privileged，并仅使用 `/cache`。需要更高权限时，应使用隔离的专用 Runner。

不要提交或删除 `runner/config/`；GitLab 暂时离线时也无需重新注册。

## 官方参考

- [GitLab Runner](https://docs.gitlab.com/runner/)
- [在 Docker 中运行 Runner](https://docs.gitlab.com/runner/install/docker/)
- [Runner 安全说明](https://docs.gitlab.com/runner/security/)
