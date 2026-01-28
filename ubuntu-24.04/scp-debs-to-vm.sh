#!/usr/bin/env bash
# 若在 NFS/noexec 挂载下无法直接执行，请用: bash scp-debs-to-vm.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKVM_X86_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

SSH_HOST="${SSH_HOST:-localhost}"
SSH_PORT="${SSH_PORT:-2222}"
SSH_USER="${SSH_USER:-mrgeek}"
SSH_PASS="${SSH_PASS:-111}"

DEST_DIR="${DEST_DIR:-/home/${SSH_USER}/debs}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

install_if_missing() {
  local pkg="$1"
  if need_cmd apt-get; then
    sudo apt-get update -y
    sudo apt-get install -y "$pkg"
    return 0
  fi
  echo "错误: 缺少依赖 $pkg，且未检测到 apt-get；请手动安装后重试" >&2
  return 1
}

if ! need_cmd scp; then
  echo "缺少 scp，尝试安装 openssh-client..."
  install_if_missing openssh-client
fi

if ! need_cmd sshpass; then
  echo "缺少 sshpass（用于免交互输入密码），尝试安装..."
  install_if_missing sshpass
fi

shopt -s nullglob
DEBS=( "${PKVM_X86_DIR}"/*.deb )
if [ "${#DEBS[@]}" -eq 0 ]; then
  echo "错误: 在 ${PKVM_X86_DIR} 未找到任何 .deb 文件" >&2
  exit 1
fi

SSH_OPTS=(
  -p "${SSH_PORT}"
  -o "StrictHostKeyChecking=no"
  -o "UserKnownHostsFile=/dev/null"
  -o "ConnectTimeout=3"
)

echo "等待虚拟机 SSH 就绪 (${SSH_USER}@${SSH_HOST}:${SSH_PORT}) ..."
for _ in $(seq 1 60); do
  if sshpass -p "${SSH_PASS}" ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" "true" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

echo "在虚拟机内创建目录: ${DEST_DIR}"
sshpass -p "${SSH_PASS}" ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" "mkdir -p '${DEST_DIR}'"

echo "开始上传 ${#DEBS[@]} 个 deb 包到 ${SSH_USER}@${SSH_HOST}:${DEST_DIR}/"
sshpass -p "${SSH_PASS}" scp -P "${SSH_PORT}" \
  -o "StrictHostKeyChecking=no" -o "UserKnownHostsFile=/dev/null" \
  "${DEBS[@]}" "${SSH_USER}@${SSH_HOST}:${DEST_DIR}/"

echo "完成。虚拟机内 deb 目录: ${DEST_DIR}"
