#!/usr/bin/env bash

set -euo pipefail
umask 077

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$ROOT_DIR/docker-compose.yml"
VERSION_FILE="$ROOT_DIR/version.env"
RUNNER_DIR="$ROOT_DIR/runner"
CONFIG_DIR="$RUNNER_DIR/config"
CONFIG_FILE="$CONFIG_DIR/config.toml"
SYSTEM_ID_FILE="$CONFIG_DIR/.runner_system_id"
REGISTER_LOCK="$CONFIG_DIR/.register.lock"
SERVICE_NAME="dockseed-gitlab-runner"

JOB_IMAGE="alpine:3.22"

readonly ROOT_DIR COMPOSE_FILE VERSION_FILE RUNNER_DIR CONFIG_DIR
readonly CONFIG_FILE SYSTEM_ID_FILE REGISTER_LOCK SERVICE_NAME
readonly JOB_IMAGE

log() { printf '[runner] %s\n' "$*"; }
die() { printf '[runner] ERROR: %s\n' "$*" >&2; exit 1; }

show_help() {
  cat <<'EOF'
dockseed-gitlab-runner

首次使用
  ./start.sh register --url https://gitlab.example.com
  ./start.sh up
  ./start.sh verify

命令
  help      显示帮助；不读取配置，也不检查 Docker
  register --url <GitLab URL> [--clone-url <clone URL>]
            隐藏读取 glrt- token 并注册一个 Runner
  up        按 version.env 启动或更新 Runner
  status    查看本地 Runner 容器状态
  verify    检查 Runner 与 GitLab 的连接和注册
  logs      显示最近 200 行日志并持续跟随
  stop      停止 Runner，保留注册配置和缓存

说明
  --url 使用 GitLab UI 创建 Runner 后 Step 1 显示的 URL。
  --clone-url 默认不设置；仅当 Job 需要不同的内部克隆地址时显式提供。
  首次 register 时 GitLab 必须在线；注册后 Runner 可以先于 GitLab 启动。
  token 不要手动写入环境文件或命令行；注册后仅由 Runner 保存到 config.toml。
  重复 register 不会追加第二个 Runner。
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

compose() {
  [[ -f "$VERSION_FILE" && ! -L "$VERSION_FILE" ]] || \
    die "version.env 缺失或不是普通文件"
  (
    unset GITLAB_RUNNER_VERSION
    docker compose --project-name "$SERVICE_NAME" --env-file "$VERSION_FILE" -f "$COMPOSE_FILE" "$@"
  )
}

tighten_permissions() {
  local path

  for path in "$CONFIG_FILE" "$SYSTEM_ID_FILE"; do
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
  mkdir -p "$CONFIG_DIR"
  chmod 700 "$RUNNER_DIR" "$CONFIG_DIR"
  tighten_permissions
}

reject_existing_config() {
  [[ ! -e "$CONFIG_FILE" || -f "$CONFIG_FILE" ]] || die "config.toml 存在但不是普通文件"
  [[ ! -s "$CONFIG_FILE" ]] || \
    die "检测到现有 config.toml；不会覆盖或追加注册，请按 README 的重新注册流程处理"
}

validate_config() {
  [[ -s "$CONFIG_FILE" ]] || die "尚未注册；请先在 GitLab UI 创建 Runner，再运行 ./start.sh register"
  awk '
    BEGIN { section="other" }
    /^[[:space:]]*\[\[runners\]\][[:space:]]*(#.*)?$/ {
      runners+=1; section="runner"; next
    }
    /^[[:space:]]*\[/ { section="other"; next }
    {
      if (index($0, "/var/run/docker.sock")) unsafe_socket=1
      if ($0 ~ /^[[:space:]]*(services_)?privileged[[:space:]]*=[[:space:]]*true/) unsafe_privileged=1
      if (section == "runner" && $0 ~ /^[[:space:]]*executor[[:space:]]*=[[:space:]]*"docker"[[:space:]]*$/) executor=1
    }
    END {
      valid = runners == 1 && executor && !unsafe_privileged && !unsafe_socket
      exit !valid
    }
  ' "$CONFIG_FILE" || \
    die "config.toml 不符合安全基线：需要唯一的 Docker Runner，且不得启用 privileged 或为 Job 挂载 Docker socket"
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
  local runner_token="" status runner_url="" clone_url="" option value
  local seen_url=0 seen_clone_url=0
  local -a register_args

  while (($# > 0)); do
    option="$1"
    case "$option" in
      --url|--clone-url)
        (($# >= 2)) && [[ -n "$2" && "$2" != -* ]] || \
          die "register 的 $option 缺少 URL 参数"
        value="$2"
        shift 2
        ;;
      --url=*|--clone-url=*)
        value="${option#*=}"
        option="${option%%=*}"
        [[ -n "$value" ]] || die "register 的 $option 缺少 URL 参数"
        shift
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
    esac
  done

  ((seen_url == 1)) || die "register 必须提供 --url <GitLab UI Step 1 URL>"
  valid_url "$runner_url" || die "--url 必须是有效的 http:// 或 https:// URL"
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
    --name "$SERVICE_NAME"
    --executor docker
    --docker-image "$JOB_IMAGE"
    --unhealthy-requests-limit 3
    --unhealthy-interval 30s
    --docker-privileged=false
    --docker-volumes /cache
    --docker-extra-hosts host.docker.internal:host-gateway
  )

  ensure_layout
  reject_existing_config

  mkdir "$REGISTER_LOCK" 2>/dev/null || \
    die "另一个注册过程正在运行，或存在遗留的 runner/config/.register.lock"
  trap 'rmdir "$REGISTER_LOCK" 2>/dev/null || true' EXIT
  reject_existing_config

  check_docker
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

  log "正在注册；GitLab 必须在线，token 通过标准输入传入且不会进入 Docker 命令参数"
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

  validate_config
  rmdir "$REGISTER_LOCK"
  trap - EXIT
  log "注册完成。下一步：./start.sh up，然后 ./start.sh verify"
}

command_up() {
  local parse_output

  require_no_args up "$@"
  ensure_layout
  validate_config
  check_docker
  if ! parse_output="$(run_runner_command list --config /etc/gitlab-runner/config.toml)"; then
    [[ -z "$parse_output" ]] || printf '%s\n' "$parse_output" >&2
    die "Runner 本地配置解析失败"
  fi
  compose up -d --no-deps "$SERVICE_NAME"
  compose ps "$SERVICE_NAME"
  log "Runner 已启动；本命令未检查 GitLab，需要远端检查时运行 ./start.sh verify"
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
    die "Runner 无法通过 GitLab 验证；请确认 GitLab 在线且注册未被撤销"
  log "GitLab 连接与 Runner 注册验证通过"
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
    up) command_up "$@" ;;
    status) command_status "$@" ;;
    verify) command_verify "$@" ;;
    logs) command_logs "$@" ;;
    stop) command_stop "$@" ;;
    *) show_help >&2; die "未知命令：$command" ;;
  esac
}

main "$@"
