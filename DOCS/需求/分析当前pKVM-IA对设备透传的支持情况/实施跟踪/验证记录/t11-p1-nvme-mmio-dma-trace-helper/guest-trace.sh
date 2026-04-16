#!/usr/bin/env bash
set -euo pipefail

TRACE_DIR=/sys/kernel/tracing
DEV=
BS=4096
COUNT=64
OUT_DIR=
USE_PID_FILTER=1

EVENTS=(
  pkvmdma_guest_nvme_queue_rq
  pkvmdma_guest_nvme_prep_rq
  pkvmdma_guest_nvme_map_data
  pkvmdma_guest_nvme_setup_prp_simple
  pkvmdma_guest_nvme_setup_sgl_simple
  pkvmdma_guest_dma_map_bvec
  pkvmdma_guest_dma_map_sgtable
  pkvmdma_guest_nvme_write_sq_db
  pkvmdma_guest_direct_mmio_write
  pkvmdma_guest_direct_mmio_read
  pkvmdma_guest_fallback_mmio_write
  pkvmdma_guest_fallback_mmio_read
)

usage() {
  cat <<'EOF'
Usage:
  guest-trace.sh --dev /dev/nvme0n1 [--bs 4096] [--count 64] [--out-dir DIR] [--trace-dir DIR] [--no-pid-filter]

What it traces during one dd window:
  - nvme_queue_rq
  - nvme_prep_rq
  - nvme_map_data
  - nvme_setup_prp_simple / nvme_setup_sgl_simple
  - dma_map_bvec / dma_map_sgtable
  - nvme_write_sq_db
  - pkvm_direct_mmio_write / pkvm_direct_mmio_read
  - mmio_write / mmio_read
EOF
}

log() {
  echo "[guest-trace] $*"
}

die() {
  echo "[guest-trace] ERROR: $*" >&2
  exit 1
}

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "must run as root"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dev)
        DEV=$2
        shift 2
        ;;
      --bs)
        BS=$2
        shift 2
        ;;
      --count)
        COUNT=$2
        shift 2
        ;;
      --out-dir)
        OUT_DIR=$2
        shift 2
        ;;
      --trace-dir)
        TRACE_DIR=$2
        shift 2
        ;;
      --no-pid-filter)
        USE_PID_FILTER=0
        shift
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

  [[ -n "$DEV" ]] || die "--dev is required"
  [[ -b "$DEV" ]] || die "device not found: $DEV"
  [[ -n "$OUT_DIR" ]] || OUT_DIR="/tmp/pkvm-guest-trace-$(date -u +%Y%m%d-%H%M%S)"
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
  echo 0 > "$TRACE_DIR/tracing_on" 2>/dev/null || true
  echo > "$TRACE_DIR/set_event_pid" 2>/dev/null || true
  for event in "${EVENTS[@]}"; do
    [[ -d "$TRACE_DIR/events/kprobes/$event" ]] && echo 0 > "$TRACE_DIR/events/kprobes/$event/enable" || true
  done
  for event in "${EVENTS[@]}"; do
    event_remove "$event"
  done
}

count_event() {
  local event=$1
  local trace_file=$2
  grep -c "kprobes:${event}:" "$trace_file" 2>/dev/null || true
}

add_probe_if_symbol() {
  local event=$1
  local spec=$2
  local sym=$3

  if symbol_exists "$sym"; then
    echo "$spec" >> "$TRACE_DIR/kprobe_events"
    echo 1 > "$TRACE_DIR/events/kprobes/$event/enable"
    echo "$event $sym enabled" >> "$OUT_DIR/guest-summary.txt"
  else
    echo "$event $sym skipped(symbol-missing)" >> "$OUT_DIR/guest-summary.txt"
  fi
}

resolve_guest_pci_info() {
  local block dev_path resource_line start end flags
  block=$(basename "$DEV")
  dev_path=$(readlink -f "/sys/block/$block/device" || true)
  if [[ -z "$dev_path" ]]; then
    return 0
  fi

  GUEST_BDF=$(grep -oE '[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9]+' <<<"$dev_path" | tail -n1 || true)
  if [[ -z "${GUEST_BDF:-}" ]]; then
    return 0
  fi

  resource_line=$(sed -n '1p' "/sys/bus/pci/devices/$GUEST_BDF/resource" 2>/dev/null || true)
  if [[ -n "$resource_line" ]]; then
    read -r start end flags <<<"$resource_line"
    GUEST_BAR0_START=$start
    GUEST_BAR0_END=$end
    GUEST_BAR0_FLAGS=$flags
  fi
}

setup_probes() {
  mkdir -p "$OUT_DIR"
  : > "$OUT_DIR/guest-summary.txt"

  echo 0 > "$TRACE_DIR/tracing_on"
  cleanup_events
  echo > "$TRACE_DIR/trace"

  add_probe_if_symbol \
    pkvmdma_guest_nvme_queue_rq \
    "p:pkvmdma_guest_nvme_queue_rq nvme_queue_rq" \
    nvme_queue_rq

  add_probe_if_symbol \
    pkvmdma_guest_nvme_prep_rq \
    "p:pkvmdma_guest_nvme_prep_rq nvme_prep_rq" \
    nvme_prep_rq

  add_probe_if_symbol \
    pkvmdma_guest_nvme_map_data \
    "p:pkvmdma_guest_nvme_map_data nvme_map_data" \
    nvme_map_data

  add_probe_if_symbol \
    pkvmdma_guest_nvme_setup_prp_simple \
    "p:pkvmdma_guest_nvme_setup_prp_simple nvme_setup_prp_simple" \
    nvme_setup_prp_simple

  add_probe_if_symbol \
    pkvmdma_guest_nvme_setup_sgl_simple \
    "p:pkvmdma_guest_nvme_setup_sgl_simple nvme_setup_sgl_simple" \
    nvme_setup_sgl_simple

  add_probe_if_symbol \
    pkvmdma_guest_dma_map_bvec \
    "p:pkvmdma_guest_dma_map_bvec dma_map_bvec" \
    dma_map_bvec

  add_probe_if_symbol \
    pkvmdma_guest_dma_map_sgtable \
    "p:pkvmdma_guest_dma_map_sgtable dma_map_sgtable" \
    dma_map_sgtable

  add_probe_if_symbol \
    pkvmdma_guest_nvme_write_sq_db \
    "p:pkvmdma_guest_nvme_write_sq_db nvme_write_sq_db" \
    nvme_write_sq_db

  add_probe_if_symbol \
    pkvmdma_guest_direct_mmio_write \
    "p:pkvmdma_guest_direct_mmio_write pkvm_direct_mmio_write size=%di:s32 vaddr=%si:u64 val=%dx:u64" \
    pkvm_direct_mmio_write

  add_probe_if_symbol \
    pkvmdma_guest_direct_mmio_read \
    "p:pkvmdma_guest_direct_mmio_read pkvm_direct_mmio_read size=%di:s32 vaddr=%si:u64" \
    pkvm_direct_mmio_read

  add_probe_if_symbol \
    pkvmdma_guest_fallback_mmio_write \
    "p:pkvmdma_guest_fallback_mmio_write mmio_write size=%di:s32 addr=%si:u64 val=%dx:u64" \
    mmio_write

  add_probe_if_symbol \
    pkvmdma_guest_fallback_mmio_read \
    "p:pkvmdma_guest_fallback_mmio_read mmio_read size=%di:s32 addr=%si:u64" \
    mmio_read
}

run_dd_window() {
  local pid_file runner_pid trace_file dd_log rc
  trace_file="$OUT_DIR/guest-trace.txt"
  dd_log="$OUT_DIR/guest-dd.log"
  pid_file=$(mktemp)

  echo > "$TRACE_DIR/trace"

  if [[ $USE_PID_FILTER -eq 1 ]]; then
    bash -c '
      echo $$ > "$1"
      kill -STOP $$
      exec dd if="$2" of=/dev/null bs="$3" count="$4" iflag=direct status=none
    ' _ "$pid_file" "$DEV" "$BS" "$COUNT" >"$dd_log" 2>&1 &
    runner_pid=$!

    for _ in $(seq 1 100); do
      [[ -s "$pid_file" ]] && break
      sleep 0.02
    done
    [[ -s "$pid_file" ]] || die "failed to get dd pid"

    echo "$(cat "$pid_file")" > "$TRACE_DIR/set_event_pid"
    echo 1 > "$TRACE_DIR/tracing_on"
    kill -CONT "$(cat "$pid_file")"
    wait "$runner_pid" || rc=$?
  else
    echo 1 > "$TRACE_DIR/tracing_on"
    dd if="$DEV" of=/dev/null bs="$BS" count="$COUNT" iflag=direct status=none >"$dd_log" 2>&1 || rc=$?
  fi

  rc=${rc:-0}
  echo 0 > "$TRACE_DIR/tracing_on"
  cat "$TRACE_DIR/trace" > "$trace_file"
  rm -f "$pid_file"
  DD_RC=$rc
}

write_summary() {
  {
    echo
    echo "runtime:"
    echo "DEV=$DEV"
    echo "BS=$BS"
    echo "COUNT=$COUNT"
    echo "USE_PID_FILTER=$USE_PID_FILTER"
    echo "DD_RC=$DD_RC"
    [[ -n "${GUEST_BDF:-}" ]] && echo "GUEST_BDF=$GUEST_BDF"
    [[ -n "${GUEST_BAR0_START:-}" ]] && echo "GUEST_BAR0_START=$GUEST_BAR0_START"
    [[ -n "${GUEST_BAR0_END:-}" ]] && echo "GUEST_BAR0_END=$GUEST_BAR0_END"
    [[ -n "${GUEST_BAR0_FLAGS:-}" ]] && echo "GUEST_BAR0_FLAGS=$GUEST_BAR0_FLAGS"
    echo
    echo "counts:"
    for event in "${EVENTS[@]}"; do
      printf '%s=%s\n' "$event" "$(count_event "$event" "$OUT_DIR/guest-trace.txt")"
    done
  } >> "$OUT_DIR/guest-summary.txt"
}

main() {
  parse_args "$@"
  require_root
  ensure_tracefs
  resolve_guest_pci_info

  trap cleanup_events EXIT
  setup_probes
  run_dd_window
  write_summary

  log "summary=$OUT_DIR/guest-summary.txt"
  log "trace=$OUT_DIR/guest-trace.txt"
  log "dd-log=$OUT_DIR/guest-dd.log"
}

main "$@"
