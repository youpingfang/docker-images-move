#!/usr/bin/env bash
set -euo pipefail

# Docker image migration helper
# Supports both interactive menu mode and direct CLI mode.

VERSION="1.0.0"
DEFAULT_REMOTE_DIR="/mnt"
DEFAULT_USER="root"
DEFAULT_PORT="22"
DEFAULT_LOCAL_DIR="/mnt/docker-images-move"

GREEN='\033[40;32m'
YELLOW='\033[40;33m'
RED='\033[40;31m'
NC='\033[0m'

log() { echo -e "${GREEN}==>${NC} $*"; }
warn() { echo -e "${YELLOW}WARN:${NC} $*" >&2; }
fail() { echo -e "${RED}ERROR:${NC} $*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || fail "缺少命令: $1"; }

usage() {
  cat <<USAGE
Docker 镜像迁移工具 v${VERSION}

用法:
  dim                                    # 快速向导：选镜像编号 -> 输入 IP -> 迁移
  bash images.sh                         # 同 dim，进入快速向导
  bash images.sh menu                    # 传统交互菜单
  bash images.sh ls                      # 编号查看本机镜像
  bash images.sh s IMAGE...              # 保存镜像到本机目录
  bash images.sh l FILE...               # 从 tar/tar.gz 加载镜像
  bash images.sh m IP                    # 不知道镜像名：弹编号列表选择后迁移
  bash images.sh m IP IMAGE...           # 快捷迁移到 IP，默认 root/22//mnt
  bash images.sh m IP:PORT IMAGE...      # 快捷指定端口
  bash images.sh m USER@IP IMAGE...      # 快捷指定用户
  bash images.sh p                       # 提示输入源服务器 IP，再拉取镜像到本机
  bash images.sh p IP                    # 从远端 IP 拉取镜像到本机
  bash images.sh move -H IP IMAGE...     # 完整参数模式
  bash images.sh pull -H IP              # 完整拉取模式：远端选镜像 -> 拉到本机

move 常用参数:
  -H, --host IP            目标服务器 IP/域名（必填）
  -u, --user USER          SSH 用户，默认: ${DEFAULT_USER}
  -p, --port PORT          SSH 端口，默认: ${DEFAULT_PORT}
  -r, --remote-dir DIR     远端目录，默认: ${DEFAULT_REMOTE_DIR}
  -o, --output-dir DIR     本地临时目录，默认: ${DEFAULT_LOCAL_DIR}
      --no-load            只上传，不在远端加载
      --keep-local         保留本地 tar.gz
      --remove-remote      远端加载后删除 tar.gz（默认保留）
      --no-compress        不压缩，保存为 .tar
      --ssh-opts OPTS      额外 SSH/SCP 参数，如: "-o StrictHostKeyChecking=no"

推荐用短命令:
  bash images.sh m 1.2.3.4              # 不填镜像名会让你选编号
  bash images.sh m 1.2.3.4 nginx:alpine
  bash images.sh m 1.2.3.4 redis:7 mysql:8
  bash images.sh m 1.2.3.4:2222 redis:7
  bash images.sh m admin@1.2.3.4 nginx:alpine
  bash images.sh p 1.2.3.4              # 在 B 机器运行，从 A 拉镜像到 B

完整参数示例:
  bash images.sh move -H 1.2.3.4 nginx:alpine
  bash images.sh move -H 1.2.3.4 -u root -p 2222 redis:7 mysql:8
  bash images.sh move -H 1.2.3.4 -r /mnt myapp:latest
USAGE
}

safe_name() {
  echo "$1" | sed 's#[/:@]#_#g; s#[^A-Za-z0-9_.-]#_#g'
}

list_images() {
  need_cmd docker
  docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}\t{{.CreatedSince}}'
}

resolve_image() {
  local image="$1"
  docker image inspect "$image" >/dev/null 2>&1 || fail "本机不存在镜像: $image"
  echo "$image"
}

image_refs() {
  docker images --format '{{.Repository}}:{{.Tag}}' | sed '/<none>/d'
}

image_refs_with_size() {
  docker images --format '{{.Repository}}:{{.Tag}}	{{.Size}}' | sed '/<none>/d'
}

list_images_numbered() {
  need_cmd docker
  local n=1 line ref size
  image_refs_with_size | while IFS=$'	' read -r ref size; do
    printf '%3d) %-45s %s
' "$n" "$ref" "$size"
    n=$((n + 1))
  done
}

select_images_by_number() {
  need_cmd docker
  local refs_file nums selected ref total
  refs_file="$(mktemp)"
  image_refs_with_size > "$refs_file"
  total="$(wc -l < "$refs_file" | tr -d ' ')"
  [ "$total" -gt 0 ] || { rm -f "$refs_file"; fail "本机没有可用镜像"; }

  echo "本机镜像列表：" >&2
  awk -F '\t' '{printf "%3d) %-45s %s\n", NR, $1, $2}' "$refs_file" >&2
  echo >&2
  read -r -p "输入编号，多个用空格，如 1 3 5: " nums </dev/tty
  [ -n "$nums" ] || { rm -f "$refs_file"; fail "未选择镜像"; }

  selected=""
  local num
  for num in $nums; do
    case "$num" in
      *[!0-9]*|'') rm -f "$refs_file"; fail "编号无效: $num" ;;
    esac
    [ "$num" -ge 1 ] && [ "$num" -le "$total" ] || { rm -f "$refs_file"; fail "编号超出范围: $num"; }
    ref="$(sed -n "${num}p" "$refs_file" | cut -f1)"
    selected="${selected}${ref}
"
  done
  rm -f "$refs_file"
  printf '%b' "$selected"
}

select_remote_images_by_number() {
  local -n ssh_cmd_ref="$1"
  local target="$2"
  local refs_file nums selected ref total
  refs_file="$(mktemp)"
  "${ssh_cmd_ref[@]}" "$target" "docker images --format '{{.Repository}}:{{.Tag}}	{{.Size}}' | sed '/<none>/d'" > "$refs_file"
  total="$(wc -l < "$refs_file" | tr -d ' ')"
  [ "$total" -gt 0 ] || { rm -f "$refs_file"; fail "远端没有可用镜像"; }

  echo "远端镜像列表：" >&2
  awk -F '\t' '{printf "%3d) %-45s %s\n", NR, $1, $2}' "$refs_file" >&2
  echo >&2
  read -r -p "输入编号，多个用空格，如 1 3 5: " nums </dev/tty
  [ -n "$nums" ] || { rm -f "$refs_file"; fail "未选择镜像"; }

  selected=""
  local num
  for num in $nums; do
    case "$num" in
      *[!0-9]*|'') rm -f "$refs_file"; fail "编号无效: $num" ;;
    esac
    [ "$num" -ge 1 ] && [ "$num" -le "$total" ] || { rm -f "$refs_file"; fail "编号超出范围: $num"; }
    ref="$(sed -n "${num}p" "$refs_file" | cut -f1)"
    selected="${selected}${ref}\n"
  done
  rm -f "$refs_file"
  printf '%b' "$selected"
}

parse_target() {
  local target="$1"
  PARSED_USER="$DEFAULT_USER"
  PARSED_HOST="$target"
  PARSED_PORT="$DEFAULT_PORT"
  if [[ "$PARSED_HOST" == *@* ]]; then
    PARSED_USER="${PARSED_HOST%@*}"
    PARSED_HOST="${PARSED_HOST#*@}"
  fi
  if [[ "$PARSED_HOST" == *:* ]]; then
    PARSED_PORT="${PARSED_HOST##*:}"
    PARSED_HOST="${PARSED_HOST%:*}"
  fi
}

save_one_image() {
  local image="$1"
  local out_dir="$2"
  local compress="$3"
  local stamp archive
  stamp="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$out_dir"

  image="$(resolve_image "$image")"
  if [ "$compress" = "1" ]; then
    archive="$out_dir/$(safe_name "$image")-${stamp}.tar.gz"
    log "保存镜像: $image -> $archive"
    docker save "$image" | gzip -c > "$archive"
  else
    archive="$out_dir/$(safe_name "$image")-${stamp}.tar"
    log "保存镜像: $image -> $archive"
    docker save -o "$archive" "$image"
  fi
  du -h "$archive" | awk '{print "大小: "$1"\t文件: "$2}'
  echo "$archive"
}

save_images() {
  local out_dir="$1"
  local compress="$2"
  shift 2
  [ "$#" -gt 0 ] || fail "请提供镜像名"
  local image
  for image in "$@"; do
    save_one_image "$image" "$out_dir" "$compress"
  done
}

load_images() {
  need_cmd docker
  [ "$#" -gt 0 ] || fail "请提供 tar/tar.gz 文件"
  local file
  for file in "$@"; do
    [ -f "$file" ] || fail "文件不存在: $file"
    log "加载镜像: $file"
    case "$file" in
      *.tar.gz|*.tgz) gzip -dc "$file" | docker load ;;
      *.tar) docker load -i "$file" ;;
      *) fail "仅支持 .tar / .tar.gz / .tgz: $file" ;;
    esac
  done
}

move_images() {
  need_cmd docker
  need_cmd ssh
  need_cmd scp
  need_cmd gzip

  local host="" user="$DEFAULT_USER" port="$DEFAULT_PORT" remote_dir="$DEFAULT_REMOTE_DIR"
  local out_dir="$DEFAULT_LOCAL_DIR" no_load=0 keep_local=0 keep_remote=1 compress=1 ssh_opts=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -H|--host) host="${2:-}"; shift 2 ;;
      -u|--user) user="${2:-}"; shift 2 ;;
      -p|--port) port="${2:-}"; shift 2 ;;
      -r|--remote-dir) remote_dir="${2:-}"; shift 2 ;;
      -o|--output-dir) out_dir="${2:-}"; shift 2 ;;
      --no-load) no_load=1; shift ;;
      --keep-local) keep_local=1; shift ;;
      --keep-remote) keep_remote=1; shift ;;
      --remove-remote) keep_remote=0; shift ;;
      --no-compress) compress=0; shift ;;
      --ssh-opts) ssh_opts="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      --) shift; break ;;
      -*) fail "未知参数: $1" ;;
      *) break ;;
    esac
  done

  [ -n "$host" ] || fail "move 模式必须指定 -H/--host"
  [ "$#" -gt 0 ] || fail "move 模式请提供至少一个镜像名"

  mkdir -p "$out_dir"
  local target="${user}@${host}"
  local control_path="/tmp/dim-ssh-%C"
  # shellcheck disable=SC2206
  local extra_opts=($ssh_opts)
  local mux_opts=(-o ControlMaster=auto -o ControlPersist=10m -o ControlPath="$control_path")
  local ssh_cmd=(ssh -p "$port" "${mux_opts[@]}" "${extra_opts[@]}")
  local scp_cmd=(scp -P "$port" "${mux_opts[@]}" "${extra_opts[@]}")

  log "检查远端目录: ${target}:${remote_dir}"
  "${ssh_cmd[@]}" "$target" "mkdir -p '$remote_dir' && test -w '$remote_dir' && command -v docker >/dev/null"

  local image archive remote_file base
  for image in "$@"; do
    archive="$(save_one_image "$image" "$out_dir" "$compress" | tail -n 1)"
    base="$(basename "$archive")"
    remote_file="${remote_dir}/${base}"

    log "上传: $archive -> ${target}:${remote_file}"
    "${scp_cmd[@]}" "$archive" "${target}:${remote_file}"

    if [ "$no_load" -eq 0 ]; then
      log "远端加载镜像: ${target}:${remote_file}"
      case "$remote_file" in
        *.tar.gz|*.tgz) "${ssh_cmd[@]}" "$target" "gzip -dc '$remote_file' | docker load" ;;
        *.tar) "${ssh_cmd[@]}" "$target" "docker load -i '$remote_file'" ;;
      esac
      if [ "$keep_remote" -eq 0 ]; then
        log "删除远端临时包: $remote_file"
        "${ssh_cmd[@]}" "$target" "rm -f '$remote_file'"
      fi
    else
      log "已上传但未加载: $remote_file"
    fi

    if [ "$keep_local" -eq 0 ]; then
      log "删除本地临时包: $archive"
      rm -f "$archive"
    fi
  done

  # 主动关闭复用连接；失败不影响迁移结果。
  "${ssh_cmd[@]}" -O exit "$target" >/dev/null 2>&1 || true
  log "迁移完成"
}


quick_move() {
  [ "$#" -ge 1 ] || fail "用法: bash images.sh m IP [镜像名...]；例: bash images.sh m 1.2.3.4 nginx:alpine"
  local target="$1"
  shift
  local user="$DEFAULT_USER" host="$target" port="$DEFAULT_PORT"

  if [[ "$host" == *@* ]]; then
    user="${host%@*}"
    host="${host#*@}"
  fi
  if [[ "$host" == *:* ]]; then
    port="${host##*:}"
    host="${host%:*}"
  fi

  if [ "$#" -eq 0 ]; then
    mapfile -t chosen < <(select_images_by_number)
    [ "${#chosen[@]}" -gt 0 ] || fail "未选择任何镜像，已停止迁移"
    move_images -H "$host" -u "$user" -p "$port" -r "$DEFAULT_REMOTE_DIR" "${chosen[@]}"
  else
    move_images -H "$host" -u "$user" -p "$port" -r "$DEFAULT_REMOTE_DIR" "$@"
  fi
}

pull_images() {
  need_cmd docker
  need_cmd ssh
  need_cmd gzip

  local host="" user="$DEFAULT_USER" port="$DEFAULT_PORT" out_dir="$DEFAULT_LOCAL_DIR"
  local keep_local=1 load_local=1 ssh_opts=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -H|--host) host="${2:-}"; shift 2 ;;
      -u|--user) user="${2:-}"; shift 2 ;;
      -p|--port) port="${2:-}"; shift 2 ;;
      -o|--output-dir) out_dir="${2:-}"; shift 2 ;;
      --no-load) load_local=0; shift ;;
      --remove-local) keep_local=0; shift ;;
      --ssh-opts) ssh_opts="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      --) shift; break ;;
      -*) fail "未知参数: $1" ;;
      *) break ;;
    esac
  done

  [ -n "$host" ] || fail "pull 模式必须指定 -H/--host"
  mkdir -p "$out_dir"
  local target="${user}@${host}"
  local control_path="/tmp/dim-ssh-%C"
  # shellcheck disable=SC2206
  local extra_opts=($ssh_opts)
  local mux_opts=(-o ControlMaster=auto -o ControlPersist=10m -o ControlPath="$control_path")
  local ssh_cmd=(ssh -p "$port" "${mux_opts[@]}" "${extra_opts[@]}")

  log "连接远端并检查 Docker: ${target}"
  "${ssh_cmd[@]}" "$target" "command -v docker >/dev/null && command -v gzip >/dev/null"

  local chosen=()
  if [ "$#" -eq 0 ]; then
    mapfile -t chosen < <(select_remote_images_by_number ssh_cmd "$target")
  else
    chosen=("$@")
  fi
  [ "${#chosen[@]}" -gt 0 ] || fail "未选择任何远端镜像，已停止拉取"

  local image archive stamp
  for image in "${chosen[@]}"; do
    stamp="$(date +%Y%m%d-%H%M%S)"
    archive="$out_dir/$(safe_name "$image")-${stamp}.tar.gz"
    log "从远端拉取镜像: ${target}:${image} -> $archive"
    "${ssh_cmd[@]}" "$target" "docker image inspect '$image' >/dev/null 2>&1 && docker save '$image' | gzip -c" > "$archive"
    du -h "$archive" | awk '{print "大小: "$1"\t文件: "$2}'

    if [ "$load_local" -eq 1 ]; then
      log "本机加载镜像: $archive"
      gzip -dc "$archive" | docker load
    else
      log "仅保存，不加载: $archive"
    fi

    if [ "$keep_local" -eq 0 ]; then
      log "删除本地包: $archive"
      rm -f "$archive"
    else
      log "本地包已保留: $archive"
    fi
  done

  "${ssh_cmd[@]}" -O exit "$target" >/dev/null 2>&1 || true
  log "拉取完成"
}

quick_pull() {
  local target
  if [ "$#" -ge 1 ]; then
    target="$1"
    shift
  else
    read -r -p "输入源容器服务器 IP（可用 IP:端口 或 用户@IP）: " target </dev/tty
    [ -n "$target" ] || fail "源容器服务器 IP 不能为空"
  fi
  parse_target "$target"
  pull_images -H "$PARSED_HOST" -u "$PARSED_USER" -p "$PARSED_PORT" "$@"
}

quick_wizard() {
  echo -e "${GREEN}Docker 镜像快速迁移${NC}"
  echo "流程：选镜像编号 -> 输入目标 IP -> 按提示输入 SSH 密码 -> 自动加载"
  echo

  mapfile -t chosen < <(select_images_by_number)
  [ "${#chosen[@]}" -gt 0 ] || fail "未选择任何镜像，已停止迁移"
  echo >&2
  read -r -p "输入目标 IP（可用 IP:端口 或 用户@IP）: " target </dev/tty
  [ -n "$target" ] || fail "目标 IP 不能为空"

  quick_move "$target" "${chosen[@]}"
}

interactive_menu() {
  echo
  echo -e "${GREEN}Docker 镜像迁移工具${NC}"
  echo "1) 查看本机镜像"
  echo "2) 保存镜像到本机 tar.gz"
  echo "3) 加载本机 tar/tar.gz 镜像"
  echo "4) 迁移镜像到远端服务器（保存 -> 上传 /mnt -> 远端加载）"
  echo "5) 退出"
  echo
  read -r -p "> 请选择: " num
  case "$num" in
    1)
      list_images_numbered
      ;;
    2)
      echo "不知道镜像名可以直接选编号。"
      mapfile -t chosen < <(select_images_by_number)
      read -r -p "保存目录（默认 ${DEFAULT_LOCAL_DIR}）: " out_dir
      save_images "${out_dir:-$DEFAULT_LOCAL_DIR}" 1 "${chosen[@]}"
      ;;
    3)
      echo "当前目录 tar 文件:"
      find . -maxdepth 1 -type f \( -name '*.tar' -o -name '*.tar.gz' -o -name '*.tgz' \) -printf '%f\n' 2>/dev/null || true
      read -r -p "输入文件名/路径，多个用空格分隔: " files
      load_images $files
      ;;
    4)
      read -r -p "输入目标 IP/域名: " host
      read -r -p "SSH 用户（默认 root）: " user
      read -r -p "SSH 端口（默认 22）: " port
      read -r -p "远端目录（默认 /mnt）: " remote_dir
      mapfile -t chosen < <(select_images_by_number)
      move_images -H "$host" -u "${user:-$DEFAULT_USER}" -p "${port:-$DEFAULT_PORT}" -r "${remote_dir:-$DEFAULT_REMOTE_DIR}" "${chosen[@]}"
      ;;
    5)
      exit 0
      ;;
    *)
      fail "输入数字错误"
      ;;
  esac
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    "") quick_wizard ;;
    menu) shift; interactive_menu "$@" ;;
    ls|list) shift; list_images_numbered "$@" ;;
    s|save) shift; save_images "$DEFAULT_LOCAL_DIR" 1 "$@" ;;
    l|load) shift; load_images "$@" ;;
    m) shift; quick_move "$@" ;;
    p) shift; quick_pull "$@" ;;
    pull) shift; pull_images "$@" ;;
    mv|move) shift; move_images "$@" ;;
    -h|--help|help) usage ;;
    -v|--version|version) echo "$VERSION" ;;
    *) fail "未知命令: $cmd，使用 --help 查看帮助" ;;
  esac
}

main "$@"
