#!/usr/bin/env bash
set -euo pipefail

TRACE_DIR=/sys/kernel/tracing
OUT_DIR=
STATE_FILE=
CMD=

EVENTS=(
  pkvmdma_host_meta_enter
  pkvmdma_host_meta_sync
  pkvmdma_host_enable_cap
  pkvmdma_host_sev_mmio_read
  pkvmdma_host_sev_mmio_write
)

usage() {
  cat <<'EOF'
Usage:
  host-trace.sh start --out-dir DIR [--trace-dir DIR]
  host-trace.sh stop  --out-dir DIR [--trace-dir DIR]

What it traces:
  - pkvm_vm_ioctl_set_ptdev_mmio_metadata
  - pkvm_sync_ptdev_mmio_metadata
  - pkvm_vm_ioctl_enable_cap
  - kvm_sev_es_mmio_read
  - kvm_sev_es_mmio_write
EOF
}

log() {
  echo "[host-trace] $*"
}

die() {
  echo "[host-trace] ERROR: $*" >&2
  exit 1
}

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "must run as root"
}

parse_args() {
  local cmd=${1:-}
  if [[ "$cmd" == "-h" || "$cmd" == "--help" || -z "$cmd" ]]; then
    usage
    exit 0
  fi
  shift || true

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --out-dir)
        OUT_DIR=$2
        shift 2
        ;;
      --trace-dir)
        TRACE_DIR=$2
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done

  [[ -n "$OUT_DIR" ]] || die "--out-dir is required"
  STATE_FILE="$OUT_DIR/.host-trace.state"
  CMD=$cmd
}

ensure_tracefs() {
  [[ -d "$TRACE_DIR" ]] || die "tracefs not found: $TRACE_DIR"
  [[ -w "$TRACE_DIR/kprobe_events" ]] || die "kprobe_events not writable: $TRACE_DIR/kprobe_events"
}

symbol_exists() {
  local sym=$1
  grep -Eq "[[:xdigit:]]+[[:space:]]+[[:alpha:]][[:space:]]+${sym}$" /proc/kallsyms
}

event_remove() {
  local event=$1
  echo "-:${event}" >> "$TRACE_DIR/kprobe_events" 2>/dev/null || true
}

cleanup_events() {
  local event
  for event in "${EVENTS[@]}"; do
    [[ -d "$TRACE_DIR/events/kprobes/$event" ]] && echo 0 > "$TRACE_DIR/events/kprobes/$event/enable" || true
  done
  for event in "${EVENTS[@]}"; do
    event_remove "$event"
  done
}

event_add_if_symbol() {
  local event=$1
  local spec=$2
  local sym=$3

  if symbol_exists "$sym"; then
    echo "$spec" >> "$TRACE_DIR/kprobe_events"
    echo 1 > "$TRACE_DIR/events/kprobes/$event/enable"
    echo "$event $sym enabled" >> "$OUT_DIR/host-summary.txt"
  else
    echo "$event $sym skipped(symbol-missing)" >> "$OUT_DIR/host-summary.txt"
  fi
}

count_event() {
  local event=$1
  local trace_file=$2
  grep -c "kprobes:${event}:" "$trace_file" 2>/dev/null || true
}

start_trace() {
  mkdir -p "$OUT_DIR"
  : > "$OUT_DIR/host-summary.txt"

  echo 0 > "$TRACE_DIR/tracing_on"
  cleanup_events
  echo > "$TRACE_DIR/trace"

  event_add_if_symbol \
    pkvmdma_host_meta_enter \
    "p:pkvmdma_host_meta_enter pkvm_vm_ioctl_set_ptdev_mmio_metadata" \
    pkvm_vm_ioctl_set_ptdev_mmio_metadata

  event_add_if_symbol \
    pkvmdma_host_meta_sync \
    "p:pkvmdma_host_meta_sync pkvm_sync_ptdev_mmio_metadata" \
    pkvm_sync_ptdev_mmio_metadata

  event_add_if_symbol \
    pkvmdma_host_enable_cap \
    "p:pkvmdma_host_enable_cap pkvm_vm_ioctl_enable_cap" \
    pkvm_vm_ioctl_enable_cap

  event_add_if_symbol \
    pkvmdma_host_sev_mmio_read \
    "p:pkvmdma_host_sev_mmio_read kvm_sev_es_mmio_read addr=%si:u64 size=%dx:u64" \
    kvm_sev_es_mmio_read

  event_add_if_symbol \
    pkvmdma_host_sev_mmio_write \
    "p:pkvmdma_host_sev_mmio_write kvm_sev_es_mmio_write addr=%si:u64 size=%dx:u64" \
    kvm_sev_es_mmio_write

  {
    echo "TRACE_DIR=$TRACE_DIR"
    echo "OUT_DIR=$OUT_DIR"
    echo "START_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$STATE_FILE"

  echo 1 > "$TRACE_DIR/tracing_on"
  log "tracing started, out-dir=$OUT_DIR"
}

stop_trace() {
  [[ -f "$STATE_FILE" ]] || die "state file not found: $STATE_FILE"

  echo 0 > "$TRACE_DIR/tracing_on"
  cat "$TRACE_DIR/trace" > "$OUT_DIR/host-trace.txt"
  dmesg > "$OUT_DIR/host-dmesg.txt" || true

  {
    echo
    echo "STOP_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
    echo "counts:"
    for event in "${EVENTS[@]}"; do
      printf '%s=%s\n' "$event" "$(count_event "$event" "$OUT_DIR/host-trace.txt")"
    done
  } >> "$OUT_DIR/host-summary.txt"

  cleanup_events
  rm -f "$STATE_FILE"
  log "tracing stopped, summary=$OUT_DIR/host-summary.txt"
}

main() {
  parse_args "$@"
  require_root
  ensure_tracefs

  case "$CMD" in
    start) start_trace ;;
    stop) stop_trace ;;
    *) die "unknown command: $CMD" ;;
  esac
}

main "$@"
