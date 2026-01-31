#!/usr/bin/env -S bash -e
#
# 交互式切换 GRUB 默认启动内核（每次启动都生效）。
# 参考：docker/README.Docker.md 中“重启进入 pKVM 内核”小节的 grub-set-default 用法。

set -euo pipefail

GRUB_CFG_DEFAULT="/boot/grub/grub.cfg"

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo "==> $*" >&2; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

as_root() {
  # Prefer sudo when not already root.
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    "$@"
  else
    need_cmd sudo
    sudo "$@"
  fi
}

usage() {
  cat <<'EOF'
用法:
  ./switch-kernel.sh [switch] [--all] [--dry-run] [--grub-cfg /boot/grub/grub.cfg]
  ./switch-kernel.sh list    [--all] [--grub-cfg /boot/grub/grub.cfg]
  ./switch-kernel.sh show

说明:
  - switch:  交互式选择一个启动项，并设置为默认（每次启动都优先生效）。
  - list:    列出可选启动项（默认只显示 “with Linux …” 且过滤 recovery/UEFI；加 --all 显示全部）。
  - show:    显示当前运行内核与 grubenv saved_entry/next_entry。

提示:
  - 推荐用数字选择；也可以直接粘贴 list 输出里的整行（例如：Advanced options for Ubuntu>Ubuntu, with Linux 6.12.58-pkvm）。
EOF
}

grub_cfg="${GRUB_CFG_DEFAULT}"
dry_run=0
show_all=0
cmd="${1:-}"
shift || true

while [ $# -gt 0 ]; do
  case "$1" in
    --all)
      show_all=1
      shift
      ;;
    --grub-cfg)
      [ $# -ge 2 ] || die "--grub-cfg needs a value"
      grub_cfg="$2"
      shift 2
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      break
      ;;
  esac
done

trim() {
  # shellcheck disable=SC2001
  printf "%s" "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

list_entries_raw() {
  [ -r "$grub_cfg" ] || die "cannot read grub cfg: $grub_cfg"
  need_cmd awk
  # Keep this logic aligned with docker/README.Docker.md.
  awk -F"'" '
    /^[[:space:]]*submenu / {subm=$2}
    /^[[:space:]]*menuentry / {
      title=$2
      if (subm != "") print subm ">" title; else print title
    }' "$grub_cfg"
}

is_candidate_entry() {
  local e="$1"

  # Always hide these noise entries unless --all is given.
  if [ "$show_all" -eq 0 ]; then
    case "$e" in
      *"recovery mode"*) return 1 ;;
      *"UEFI Firmware Settings"*) return 1 ;;
      # Prefer only explicit kernel entries by default.
      *"with Linux "*) : ;;
      *) return 1 ;;
    esac
  fi

  return 0
}

list_entries() {
  local i=1
  while IFS= read -r line; do
    if is_candidate_entry "$line"; then
      printf "%4d  %s\n" "$i" "$line"
      i=$((i + 1))
    fi
  done < <(list_entries_raw)
}

run_or_echo() {
  if [ "$dry_run" -eq 1 ]; then
    printf "+ %q" "$@"
    printf "\n"
    return 0
  fi
  "$@"
}

ensure_grub_default_saved() {
  # grub-set-default writes saved_entry into grubenv, but GRUB will only honor it
  # when /etc/default/grub has GRUB_DEFAULT=saved.
  local grub_defaults="/etc/default/grub"
  [ -r "$grub_defaults" ] || return 0

  local cur
  cur="$(grep -E '^GRUB_DEFAULT=' "$grub_defaults" 2>/dev/null || true)"
  if [ "$cur" = "GRUB_DEFAULT=saved" ]; then
    return 0
  fi

  note "WARNING: $grub_defaults has '$cur' (needs GRUB_DEFAULT=saved for saved_entry to take effect)"
  echo "Fix now by setting GRUB_DEFAULT=saved and running update-grub."
  printf "Apply this fix automatically? [Y/n] "
  IFS= read -r ans || true
  ans="$(trim "${ans//$'\r'/}")"
  if [ -z "$ans" ] || [[ "$ans" =~ ^[Yy]$ ]]; then
    note "updating $grub_defaults: GRUB_DEFAULT=saved"
    run_or_echo as_root cp -a "$grub_defaults" "$grub_defaults.bak.$(date +%Y%m%d-%H%M%S)"
    if as_root grep -q '^GRUB_DEFAULT=' "$grub_defaults"; then
      run_or_echo as_root sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' "$grub_defaults"
    else
      run_or_echo as_root sh -lc "echo 'GRUB_DEFAULT=saved' >> '$grub_defaults'"
    fi
  else
    note "skipping automatic fix"
  fi
}

interactive_switch() {
  mapfile -t all_entries < <(list_entries_raw)

  # Build candidate list (filtered by default).
  candidates=()
  local e
  for e in "${all_entries[@]}"; do
    if is_candidate_entry "$e"; then
      candidates+=("$e")
    fi
  done

  if [ "${#candidates[@]}" -eq 0 ]; then
    if [ "$show_all" -eq 0 ]; then
      die "no kernel-like entries found (try: ./switch-kernel.sh --all)"
    fi
    die "no menuentry found in: $grub_cfg"
  fi

  note "available entries:"
  local i=1
  for e in "${candidates[@]}"; do
    printf "%4d  %s\n" "$i" "$e"
    i=$((i + 1))
  done

  echo
  echo "Paste the NUMBER to switch, or paste the full entry line."
  printf "Selection: "
  IFS= read -r sel || true
  sel="$(trim "${sel//$'\r'/}")"
  [ -n "$sel" ] || die "empty selection"

  local chosen=""
  if [[ "$sel" =~ ^[0-9]+$ ]]; then
    local idx=$((sel - 1))
    [ "$idx" -ge 0 ] && [ "$idx" -lt "${#candidates[@]}" ] || die "index out of range (1..${#candidates[@]})"
    chosen="${candidates[$idx]}"
  else
    chosen="$sel"
  fi

  note "setting GRUB default to: $chosen"
  need_cmd grub-set-default
  run_or_echo as_root grub-set-default "$chosen"

  ensure_grub_default_saved

  # Keep grub.cfg/grubenv in sync on distros where update-grub regenerates menus.
  if command -v update-grub >/dev/null 2>&1; then
    note "running update-grub..."
    run_or_echo as_root update-grub
  else
    note "update-grub not found; skipping"
  fi

  if [ "$dry_run" -eq 0 ]; then
    note "done. current grubenv:"
    if command -v grub-editenv >/dev/null 2>&1; then
      as_root grub-editenv list || true
    fi
  fi
}

case "$cmd" in
  ""|switch)
    interactive_switch
    ;;
  list)
    list_entries
    ;;
  show)
    need_cmd uname
    echo "uname -r: $(uname -r)"
    if command -v grub-editenv >/dev/null 2>&1; then
      echo "--- grub-editenv list ---"
      as_root grub-editenv list || true
    else
      note "grub-editenv not found; skipping grubenv status"
    fi
    ;;
  ""|-h|--help|help)
    usage
    ;;
  *)
    die "unknown command: $cmd (try: ./switch-kernel.sh help)"
    ;;
esac
