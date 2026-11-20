#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
OUT="$ROOT/build/day15"
mkdir -p "$OUT/logs" "$OUT/runs" "$OUT/waves"
action=${1:-help}

open_log() {
  test -f "$OUT/latest.log" || { echo '尚无测试日志，请先运行一个测试。'; exit 1; }
  if command -v code >/dev/null; then code --reuse-window "$(readlink -f "$OUT/latest.log")"; else echo '请在资源管理器打开 build/day15/latest.log'; exit 1; fi
}
open_wave() {
  command -v gtkwave >/dev/null || { echo 'GTKWave 未安装。'; exit 1; }
  test -n "${DISPLAY:-}" || { echo 'WSLg DISPLAY 不可用，请在 WSL: Ubuntu 窗口运行。'; exit 1; }
  test -s "$OUT/waves/axi4lite_protocol.vcd" || { echo '尚无波形，请先运行 IC: 生成真实 AXI4-Lite 波形。'; exit 1; }
  nohup gtkwave "$OUT/waves/axi4lite_protocol.vcd" "$ROOT/debug/axi4lite.gtkw" > "$OUT/logs/gtkwave.log" 2>&1 < /dev/null &
  pid=$!
  sleep 2
  kill -0 "$pid" 2>/dev/null || { cat "$OUT/logs/gtkwave.log"; exit 1; }
  echo "GTKWave 已启动，PID=$pid；波形：$OUT/waves/axi4lite_protocol.vcd"
}
case "$action" in
  log) open_log; exit ;;
  wave) open_wave; exit ;;
  protocol|sanity|regression|ral|wave-generate) ;;
  *) echo '用法: bash scripts/local-dev.sh {protocol|sanity|regression|ral|wave-generate|log|wave}'; exit 2 ;;
esac
# Shared vectors and simulator outputs must not be changed by concurrent tasks.
exec 9>"$OUT/run.lock"
flock -n 9 || { echo '另一个 IC 测试正在运行，请等待结束。'; exit 1; }
stamp=$(date +%Y%m%d-%H%M%S-%N)
log="$OUT/logs/$stamp-$action.log"
exec > >(tee "$log") 2>&1
ln -sfn "logs/$(basename "$log")" "$OUT/latest.log"
echo "ACTION=$action TIME=$(date -Is)"
echo "HEAD=$(git rev-parse HEAD)"
echo "LOG=$log"

protocol() {
  python3 scripts/gen_vectors.py
  if [[ ! -f build/protocol || rtl/axi4lite_slave.sv -nt build/protocol || tb/tb_protocol.sv -nt build/protocol ]]; then
    iverilog -g2012 -s tb_protocol -o build/protocol rtl/axi4lite_slave.sv tb/tb_protocol.sv
  else echo 'CACHE_HIT: Day 1 Icarus executable'; fi
  timeout 120s vvp build/protocol
}
uvm() {
  test -x build/uvm/uvm_sim || { echo '缺少 Day 1 UVM 二进制，请按 Day 1 命令单独构建。'; return 1; }
  sha256sum --check --status "$OUT/uvm-inputs.sha256" || { echo 'UVM 源码或二进制已变化，缓存不再适用；请先显式重建并更新指纹。'; return 1; }
  echo 'CACHE_HIT: Day 1 Verilator/UVM executable (no compile)'
  testname="axi4lite_${action}_test"
  run="$OUT/runs/$stamp-$action"
  mkdir -p "$run"
  sim_status=0
  (cd "$run"; timeout 600s "$ROOT/build/uvm/uvm_sim" +UVM_TESTNAME="$testname" +verilator+seed+20261022) > "$run/simulator.log" 2>&1 || sim_status=$?
  cat "$run/simulator.log"
  python3 "$ROOT/scripts/check-uvm-result.py" "$run/simulator.log" --exit-code "$sim_status"
  echo "UVM_RESULT_GATE=PASS TEST=$testname COVERAGE=$run/coverage.dat"
}
wave_generate() {
  python3 scripts/gen_vectors.py
  exe="$OUT/protocol-wave"
  if [[ ! -f "$exe" || rtl/axi4lite_slave.sv -nt "$exe" || tb/tb_protocol.sv -nt "$exe" || debug/tb_protocol_wave.sv -nt "$exe" ]]; then
    iverilog -g2012 -s tb_protocol_wave -o "$exe" rtl/axi4lite_slave.sv tb/tb_protocol.sv debug/tb_protocol_wave.sv
  else echo 'CACHE_HIT: independent waveform executable'; fi
  timeout 120s vvp "$exe"
  test -s "$OUT/waves/axi4lite_protocol.vcd"
  echo "WAVE=$OUT/waves/axi4lite_protocol.vcd"
}
case "$action" in
  protocol) protocol ;;
  sanity|regression|ral) uvm ;;
  wave-generate) wave_generate ;;
esac
echo 'TASK_RESULT=PASS'
