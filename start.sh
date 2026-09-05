#!/usr/bin/env bash

set -euo pipefail
umask 077

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$ROOT_DIR/docker-compose.yml"
ENV_FILE="$ROOT_DIR/.env"
RUNNER_DIR="$ROOT_DIR/runner"
CONFIG_DIR="$RUNNER_DIR/config"
CONFIG_FILE="$CONFIG_DIR/config.toml"
SYSTEM_ID_FILE="$CONFIG_DIR/.runner_system_id"
# 记录注册时明确指定 --privileged 的 Runner 名，每行一个；随 runner/config 一起不提交。
PRIVILEGED_FILE="$CONFIG_DIR/.privileged_runners"
# register / unregister 共用的 config.toml 写锁。
CONFIG_LOCK="$CONFIG_DIR/.register.lock"
SERVICE_NAME="dockseed-gitlab-runner"

JOB_IMAGE="alpine:3.22"
RUNNER_NAME_PATTERN='^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$'

readonly ROOT_DIR COMPOSE_FILE ENV_FILE RUNNER_DIR CONFIG_DIR
readonly CONFIG_FILE SYSTEM_ID_FILE PRIVILEGED_FILE CONFIG_LOCK SERVICE_NAME
readonly JOB_IMAGE RUNNER_NAME_PATTERN

log() { printf '[runner] %s\n' "$*"; }
die() { printf '[runner] ERROR: %s\n' "$*" >&2; exit 1; }

show_help() {
  cat <<'EOF'
dockseed-gitlab-runner

首次使用
  ./start.sh register --url https://gitlab.example.com --name shared-docker
  ./start.sh register --url https://gitlab.example.com --name container-build --privileged
  ./start.sh up
  ./start.sh verify

命令
  help      显示帮助；不读取配置，也不检查 Docker
  register --url <GitLab URL> --name <Runner 名> [--privileged] [--clone-url <clone URL>]
            隐藏读取 glrt- token，向 config.toml 追加一个 [[runners]] 段
  unregister --name <Runner 名>
            从 GitLab 侧注销该 Runner，并从 config.toml 删除对应段；其他段不动
  up        按 .env 中的镜像版本和并发数启动或更新 Runner manager（管理全部 Runner）
  status    查看本地 Runner 容器状态
  verify    检查全部 Runner 与 GitLab 的连接和注册
  logs      显示最近 200 行日志并持续跟随
  stop      停止 Runner manager，保留注册配置和缓存

说明
  --url 使用 GitLab UI 创建 Runner 后 Step 1 显示的 URL。
  --name 是本机 config.toml 中的 Runner 名，同一名字只能注册一次；重复注册请先 unregister。
  --privileged 让该 Runner 的 Job 容器以 privileged 运行，用于 Docker-in-Docker 构建镜像；
    等同于宿主机 root，只给可信项目用。默认关闭。
  --clone-url 默认不设置；仅当 Job 需要不同的内部克隆地址时显式提供。
  register / unregister 时 GitLab 必须在线；注册后 Runner 可以先于 GitLab 启动。
  token 不要手动写入环境文件或命令行；注册后仅由 Runner 保存到 config.toml。
  RUNNER_CONCURRENT 是所有 Runner 合计的并发上限，register 不会改动它。
EOF
}

require_no_args() {
  local command="$1"
  shift
  (($# == 0)) || die "$command 不接受参数"
}

check_docker() {
  command -v docker >/dev/null 2>&1 || die "缺少 docker"
  docker compose version >/dev/null 2>&1 || die "需要 Docker Compose v2"
  docker info >/dev/null 2>&1 || die "Docker 不可用，请先启动 Docker Desktop"
}

valid_url() {
  local host label port url="$1"
  local pattern='^https?://(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9][A-Za-z0-9.-]*)(:([0-9]{1,5}))?(/[A-Za-z0-9._~!$&()*+,;=:@%/-]*)?$'
  local -a labels

  [[ "$url" =~ $pattern ]] || return 1
  host="${BASH_REMATCH[1]}"
  port="${BASH_REMATCH[3]:-}"

  if [[ "$host" == \[*\] ]]; then
    [[ "$host" == *:* ]] || return 1
  else
    [[ "$host" != .* && "$host" != *. && "$host" != *..* ]] || return 1
    IFS='.' read -r -a labels <<<"$host"
    for label in "${labels[@]}"; do
      [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done
  fi

  if [[ -n "$port" ]]; then
    ((10#$port >= 1 && 10#$port <= 65535)) || return 1
  fi
}

valid_runner_name() {
  [[ "$1" =~ $RUNNER_NAME_PATTERN ]]
}

compose() {
  [[ -f "$ENV_FILE" && ! -L "$ENV_FILE" ]] || \
    die "请先复制 .env.example 为 .env"
  (
    unset GITLAB_RUNNER_VERSION RUNNER_CONCURRENT
    docker compose --project-name "$SERVICE_NAME" --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
  )
}

# 读取 config.toml 当前的全局 concurrent 值；没有配置时输出为空。
read_concurrent() {
  [[ -s "$CONFIG_FILE" ]] || return 0
  LC_ALL=C sed -n -E 's/^concurrent[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' "$CONFIG_FILE" | head -n 1
}

# GitLab Runner 的全局并发数只从 config.toml 读取，是所有 Runner 合计的上限。
set_runner_concurrent() (
  local concurrent="$1" backup="$CONFIG_FILE.bak"

  grep -qx "concurrent = $concurrent" "$CONFIG_FILE" && return
  grep -qE '^concurrent[[:space:]]*=' "$CONFIG_FILE" || \
    die "config.toml 缺少 concurrent 配置"
  trap 'rm -f "$backup"' EXIT
  LC_ALL=C sed -i.bak -E \
    "s/^concurrent[[:space:]]*=.*/concurrent = $concurrent/" "$CONFIG_FILE"
  tighten_permissions
  log "Runner 并发数已更新为 $concurrent"
)

tighten_permissions() {
  local path

  for path in "$CONFIG_FILE" "$SYSTEM_ID_FILE" "$PRIVILEGED_FILE"; do
    if [[ -f "$path" ]] && ! chmod 600 "$path"; then
      printf '[runner] ERROR: 无法把 %s 权限设置为 600\n' "${path##*/}" >&2
      return 1
    fi
  done
}

ensure_layout() {
  [[ ! -L "$RUNNER_DIR" ]] || die "runner 不得是符号链接"
  [[ ! -L "$CONFIG_DIR" ]] || die "runner/config 不得是符号链接"
  [[ ! -L "$CONFIG_FILE" ]] || die "config.toml 不得是符号链接"
  [[ ! -L "$SYSTEM_ID_FILE" ]] || die ".runner_system_id 不得是符号链接"
  [[ ! -L "$PRIVILEGED_FILE" ]] || die ".privileged_runners 不得是符号链接"
  [[ ! -e "$CONFIG_FILE" || -f "$CONFIG_FILE" ]] || die "config.toml 存在但不是普通文件"
  [[ ! -e "$PRIVILEGED_FILE" || -f "$PRIVILEGED_FILE" ]] || die ".privileged_runners 存在但不是普通文件"
  mkdir -p "$CONFIG_DIR"
  chmod 700 "$RUNNER_DIR" "$CONFIG_DIR"
  tighten_permissions
}

acquire_config_lock() {
  mkdir "$CONFIG_LOCK" 2>/dev/null || \
    die "另一个 register/unregister 正在运行，或存在遗留的 runner/config/.register.lock"
  trap 'rmdir "$CONFIG_LOCK" 2>/dev/null || true' EXIT
}

release_config_lock() {
  rmdir "$CONFIG_LOCK"
  trap - EXIT
}

# 列出 config.toml 中每个 [[runners]] 段的 name，每行一个。
list_runner_names() {
  [[ -s "$CONFIG_FILE" ]] || return 0
  awk '
    /^[[:space:]]*\[\[runners\]\][[:space:]]*(#.*)?$/ { section="runner"; next }
    /^[[:space:]]*\[runners\./ { section="sub"; next }
    /^[[:space:]]*\[/ { section="other"; next }
    section == "runner" && match($0, /^[[:space:]]*name[[:space:]]*=[[:space:]]*"[^"]*"/) {
      line=substr($0, RSTART, RLENGTH)
      sub(/^[^"]*"/, "", line)
      sub(/"$/, "", line)
      print line
    }
  ' "$CONFIG_FILE"
}

runner_exists() {
  list_runner_names | grep -qxF -- "$1"
}

# 列出注册时明确指定 --privileged 的 Runner 名；忽略格式不合法的行。
list_privileged_names() {
  [[ -f "$PRIVILEGED_FILE" ]] || return 0
  grep -E -- "$RUNNER_NAME_PATTERN" "$PRIVILEGED_FILE" || true
}

mark_privileged() {
  local runner_name="$1"

  list_privileged_names | grep -qxF -- "$runner_name" && return
  printf '%s\n' "$runner_name" >>"$PRIVILEGED_FILE"
  chmod 600 "$PRIVILEGED_FILE"
}

unmark_privileged() {
  local runner_name="$1" remaining

  [[ -f "$PRIVILEGED_FILE" ]] || return 0
  remaining="$(list_privileged_names | grep -vxF -- "$runner_name" || true)"
  if [[ -z "$remaining" ]]; then
    rm -f "$PRIVILEGED_FILE"
  else
    printf '%s\n' "$remaining" >"$PRIVILEGED_FILE"
    chmod 600 "$PRIVILEGED_FILE"
  fi
}

# 逐段校验 config.toml：至少一个 [[runners]]；每段 executor 都是 docker；
# 任何地方都不得为 Job 挂载 Docker socket；privileged = true 只允许出现在
# 注册时明确 --privileged 并记录在 .privileged_runners 中的段。
validate_config() {
  [[ -s "$CONFIG_FILE" ]] || die "尚未注册；请先在 GitLab UI 创建 Runner，再运行 ./start.sh register"
  awk -v privileged_names="$(list_privileged_names)" '
    BEGIN {
      section="other"; runners=0
      count=split(privileged_names, list, "\n")
      for (i=1; i<=count; i++) if (list[i] != "") allowed[list[i]]=1
    }
    /^[[:space:]]*\[\[runners\]\][[:space:]]*(#.*)?$/ { runners+=1; section="runner"; next }
    /^[[:space:]]*\[runners\./ { section = runners > 0 ? "sub" : "other"; next }
    /^[[:space:]]*\[/ { section="other"; next }
    index($0, "/var/run/docker.sock") { unsafe_socket=1 }
    section == "runner" && match($0, /^[[:space:]]*name[[:space:]]*=[[:space:]]*"[^"]*"/) {
      line=substr($0, RSTART, RLENGTH)
      sub(/^[^"]*"/, "", line)
      sub(/"$/, "", line)
      name[runners]=line
    }
    section == "runner" && $0 ~ /^[[:space:]]*executor[[:space:]]*=[[:space:]]*"docker"[[:space:]]*(#.*)?$/ { executor[runners]=1 }
    (section == "runner" || section == "sub") && $0 ~ /^[[:space:]]*(services_)?privileged[[:space:]]*=[[:space:]]*true/ { privileged[runners]=1 }
    END {
      if (runners == 0) { print "config.toml 中没有 [[runners]] 段"; bad=1 }
      if (unsafe_socket) { print "config.toml 为 Job 挂载了 /var/run/docker.sock"; bad=1 }
      for (i=1; i<=runners; i++) {
        label = (i in name && name[i] != "") ? "Runner \"" name[i] "\"" : "第 " i " 个 [[runners]] 段"
        if (!(i in name) || name[i] == "") { print label " 缺少 name"; bad=1 }
        else if (name[i] in seen) { print label " 的名字重复"; bad=1 }
        else seen[name[i]]=1
        if (!(i in executor)) { print label " 的 executor 不是 docker"; bad=1 }
        if ((i in privileged) && !(name[i] in allowed)) {
          print label " 启用了 privileged，但注册时未指定 --privileged"; bad=1
        }
      }
      exit bad
    }
  ' "$CONFIG_FILE" >&2 || \
    die "config.toml 不符合安全基线：每段都必须是 Docker Runner，不得为 Job 挂载 Docker socket，privileged 只允许用于注册时明确 --privileged 的 Runner"
}

redact_output() {
  LC_ALL=C sed -E \
    -e $'s/\x1b\\[[0-9;]*[[:alpha:]]//g' \
    -e 's/glrt-[A-Za-z0-9._-]+/[REDACTED]/g' \
    -e 's/([Tt]oken=)[^[:space:]]+/\1[REDACTED]/g' \
    -e 's/([Rr]unner=)[^[:space:]]+/\1[REDACTED]/g'
}

run_runner_command() {
  local status=0

  compose run --rm --no-deps -T "$SERVICE_NAME" "$@" 2>&1 | redact_output || status="$?"
  tighten_permissions || return 1
  return "$status"
}

command_register() {
  local runner_token="" status runner_url="" clone_url="" runner_name="" option value
  local seen_url=0 seen_clone_url=0 seen_name=0 privileged=0 previous_concurrent
  local -a register_args

  while (($# > 0)); do
    option="$1"
    case "$option" in
      --url|--clone-url|--name)
        (($# >= 2)) && [[ -n "$2" && "$2" != -* ]] || \
          die "register 的 $option 缺少参数"
        value="$2"
        shift 2
        ;;
      --url=*|--clone-url=*|--name=*)
        value="${option#*=}"
        option="${option%%=*}"
        [[ -n "$value" ]] || die "register 的 $option 缺少参数"
        shift
        ;;
      --privileged)
        ((privileged == 0)) || die "register 的 --privileged 不得重复"
        privileged=1
        shift
        continue
        ;;
      -*) die "register 的未知选项：$option" ;;
      *) die "register 不接受位置参数：$option" ;;
    esac

    case "$option" in
      --url)
        ((seen_url == 0)) || die "register 的 --url 不得重复"
        runner_url="$value"
        seen_url=1
        ;;
      --clone-url)
        ((seen_clone_url == 0)) || die "register 的 --clone-url 不得重复"
        clone_url="$value"
        seen_clone_url=1
        ;;
      --name)
        ((seen_name == 0)) || die "register 的 --name 不得重复"
        runner_name="$value"
        seen_name=1
        ;;
    esac
  done

  ((seen_url == 1)) || die "register 必须提供 --url <GitLab UI Step 1 URL>"
  ((seen_name == 1)) || die "register 必须提供 --name <Runner 名>，例如 shared-docker 或 container-build"
  valid_url "$runner_url" || die "--url 必须是有效的 http:// 或 https:// URL"
  valid_runner_name "$runner_name" || \
    die "--name 只能包含字母、数字、. _ -，以字母或数字开头，最长 63 个字符"
  if ((seen_clone_url == 1)); then
    valid_url "$clone_url" || die "--clone-url 必须是有效的 http:// 或 https:// URL"
  fi

  register_args=(
    --non-interactive
    --url "$runner_url"
  )
  if ((seen_clone_url == 1)); then
    register_args+=(--clone-url "$clone_url")
  fi
  register_args+=(
    --name "$runner_name"
    --executor docker
    --docker-image "$JOB_IMAGE"
    --unhealthy-requests-limit 3
    --unhealthy-interval 30s
  )
  if ((privileged == 1)); then
    # Docker-in-Docker 构建：Job 容器 privileged；/certs/client 为 docker:dind 共享 TLS 证书预留。
    register_args+=(
      --docker-privileged=true
      --docker-volumes /certs/client
    )
  else
    register_args+=(--docker-privileged=false)
  fi
  register_args+=(
    --docker-volumes /cache
    --docker-extra-hosts host.docker.internal:host-gateway
  )

  ensure_layout
  ! runner_exists "$runner_name" || \
    die "config.toml 中已存在名为 $runner_name 的 Runner；如需重新注册，请先运行 ./start.sh unregister --name $runner_name"

  acquire_config_lock
  ! runner_exists "$runner_name" || \
    die "config.toml 中已存在名为 $runner_name 的 Runner；如需重新注册，请先运行 ./start.sh unregister --name $runner_name"

  check_docker
  compose config --quiet
  [[ -t 0 ]] || die "register 必须在交互式终端中运行，以便隐藏 token 输入"

  set +x
  if ! read -r -s -p "请输入 GitLab UI 显示的 glrt- Runner authentication token: " runner_token; then
    printf '\n'
    die "未读取到 token"
  fi
  printf '\n'
  [[ "$runner_token" =~ ^glrt-[A-Za-z0-9._-]+$ ]] || \
    die "token 格式无效；必须使用 glrt- 开头的 Runner authentication token"

  [[ -e "$CONFIG_FILE" ]] || : >"$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
  previous_concurrent="$(read_concurrent)"

  if ((privileged == 1)); then
    log "警告：$runner_name 的 Job 容器将以 privileged 运行，等同于宿主机 root，只给可信项目用"
  fi
  log "正在注册 ${runner_name}；GitLab 必须在线，token 通过标准输入传入且不会进入 Docker 命令参数"
  # gitlab-runner register 会加载已有 config.toml 并追加一个 [[runners]] 段，全局配置原样保留。
  set +e
  printf '%s\n' "$runner_token" | \
    compose run --rm --no-deps -T --entrypoint /bin/sh "$SERVICE_NAME" -c \
      'IFS= read -r CI_SERVER_TOKEN || exit 64; export CI_SERVER_TOKEN; exec gitlab-runner register "$@"' \
      dockseed-register \
      "${register_args[@]}" 2>&1 | \
    redact_output
  status="${PIPESTATUS[1]}"
  set -e
  runner_token=""
  unset runner_token
  tighten_permissions

  ((status == 0)) || \
    die "注册失败；请确认 GitLab 在线、URL 可达且 token 有效。若已写入 config.toml，请先检查，不要直接重试"

  # 到这里 GitLab 侧已经注册成功；以下任一步失败都意味着本地状态不完整，
  # 统一提示用 unregister 回退。放在子 shell 里，内部的 die 不会跳过下面的提示。
  if ! (
    runner_exists "$runner_name" || \
      die "gitlab-runner register 已返回，但 config.toml 中没有 $runner_name"
    if ((privileged == 1)); then
      mark_privileged "$runner_name"
    else
      # 同名 Runner 曾以 privileged 注册、后被手动删段时标记会残留，普通注册要清掉它。
      unmark_privileged "$runner_name"
    fi
    # 追加不应改动全局 concurrent；万一变了，恢复为注册前的值。
    if [[ -n "$previous_concurrent" && "$(read_concurrent)" != "$previous_concurrent" ]]; then
      set_runner_concurrent "$previous_concurrent"
    fi
    validate_config
  ); then
    die "GitLab 侧已注册 ${runner_name}，但本地配置未完成；请运行 ./start.sh unregister --name $runner_name 回退，或手动检查 config.toml"
  fi
  release_config_lock
  log "已注册 ${runner_name}，当前 Runner：$(list_runner_names | paste -sd ' ' -)"
  log "下一步：./start.sh up，然后 ./start.sh verify"
}

command_unregister() {
  local runner_name="" option value seen_name=0

  while (($# > 0)); do
    option="$1"
    case "$option" in
      --name)
        (($# >= 2)) && [[ -n "$2" && "$2" != -* ]] || \
          die "unregister 的 --name 缺少参数"
        value="$2"
        shift 2
        ;;
      --name=*)
        value="${option#*=}"
        [[ -n "$value" ]] || die "unregister 的 --name 缺少参数"
        shift
        ;;
      -*) die "unregister 的未知选项：$option" ;;
      *) die "unregister 不接受位置参数：$option" ;;
    esac
    ((seen_name == 0)) || die "unregister 的 --name 不得重复"
    runner_name="$value"
    seen_name=1
  done

  ((seen_name == 1)) || die "unregister 必须提供 --name <Runner 名>"
  valid_runner_name "$runner_name" || \
    die "--name 只能包含字母、数字、. _ -，以字母或数字开头，最长 63 个字符"

  ensure_layout
  [[ -s "$CONFIG_FILE" ]] || die "尚未注册任何 Runner"
  runner_exists "$runner_name" || \
    die "config.toml 中没有名为 $runner_name 的 Runner；当前有：$(list_runner_names | paste -sd ' ' -)"

  acquire_config_lock
  check_docker
  compose config --quiet

  log "正在从 GitLab 注销 ${runner_name}；GitLab 必须在线"
  # gitlab-runner unregister 先调用 GitLab API 注销，成功后才从 config.toml 删除该段。
  run_runner_command unregister --name "$runner_name" || \
    die "注销失败；请确认 GitLab 在线且该 Runner 的 token 仍有效。若 GitLab 侧已删除该 Runner，请手动从 config.toml 删除对应 [[runners]] 段"
  ! runner_exists "$runner_name" || \
    die "gitlab-runner unregister 已返回，但 config.toml 中仍有 ${runner_name}，请手动检查"

  unmark_privileged "$runner_name"
  if list_runner_names | grep -q .; then
    validate_config
    log "已注销 ${runner_name}，剩余 Runner：$(list_runner_names | paste -sd ' ' -)"
  else
    log "已注销 ${runner_name}；config.toml 中已没有 Runner，如需继续使用请重新 register"
  fi
  release_config_lock
  log "GitLab UI 中的 Runner 记录如不再需要，请在 UI 中删除"
}

command_up() {
  local parse_output runner_concurrent

  require_no_args up "$@"
  ensure_layout
  validate_config
  check_docker
  runner_concurrent="$(compose config --environment | sed -n 's/^RUNNER_CONCURRENT=//p')"
  [[ "$runner_concurrent" =~ ^[1-9][0-9]*$ ]] || \
    die "请在 .env 中将 RUNNER_CONCURRENT 配置为正整数"
  set_runner_concurrent "$runner_concurrent"
  if ! parse_output="$(run_runner_command list --config /etc/gitlab-runner/config.toml)"; then
    [[ -z "$parse_output" ]] || printf '%s\n' "$parse_output" >&2
    die "Runner 本地配置解析失败"
  fi
  compose up -d --no-deps "$SERVICE_NAME"
  compose ps "$SERVICE_NAME"
  log "Runner manager 已启动，管理的 Runner：$(list_runner_names | paste -sd ' ' -)"
  log "本命令未检查 GitLab，需要远端检查时运行 ./start.sh verify"
}

command_status() {
  require_no_args status "$@"
  check_docker
  compose ps --all "$SERVICE_NAME"
}

command_verify() {
  require_no_args verify "$@"
  ensure_layout
  validate_config
  check_docker

  run_runner_command verify || \
    die "有 Runner 无法通过 GitLab 验证；请确认 GitLab 在线且注册未被撤销"
  log "GitLab 连接与全部 Runner 注册验证通过"
}

command_logs() {
  require_no_args logs "$@"
  check_docker
  compose logs --tail=200 -f "$SERVICE_NAME"
}

command_stop() {
  require_no_args stop "$@"
  check_docker
  compose stop "$SERVICE_NAME"
  log "Runner 已停止；注册配置和缓存均已保留"
}

main() {
  local command="${1:-help}"
  shift || true

  case "$command" in
    help|-h|--help) require_no_args help "$@"; show_help ;;
    register) command_register "$@" ;;
    unregister) command_unregister "$@" ;;
    up) command_up "$@" ;;
    status) command_status "$@" ;;
    verify) command_verify "$@" ;;
    logs) command_logs "$@" ;;
    stop) command_stop "$@" ;;
    *) show_help >&2; die "未知命令：$command" ;;
  esac
}

main "$@"
