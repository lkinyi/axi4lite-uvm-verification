#!/usr/bin/env bash
# Debug-only probes; existing regression binaries, logs and waves are preserved.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
export VERILATOR_ROOT="$ROOT/.tools/verilator-src"
export UVM_HOME="$ROOT/.tools/uvm"
BASE="$ROOT/build/uvm-mem-debug"
MODE=${1:-run}
case "$MODE" in
  run|--no-gui|--view) ;;
  --help|-h)
    echo 'Usage: [MEM_WORDS=4,5] bash debug/trace-memory.sh [--no-gui|--view]'
    echo 'Default: run regression in a new directory, then open GTKWave.'
    echo '--view opens the latest successful run without simulation.'
    exit 0 ;;
  *) echo "Unknown option: $MODE" >&2; exit 2 ;;
esac
open_wave() {
    command -v gtkwave >/dev/null || { echo 'GTKWave is not installed; use --no-gui.' >&2; return 1; }
    test -n "${DISPLAY:-}" || { echo 'No DISPLAY; run in WSLg or use --no-gui.' >&2; return 1; }
    (cd "$OUT"; nohup gtkwave "$OUT/run/axi4lite_uvm.vcd" "$OUT/axi4lite-memory.gtkw" > gtkwave.log 2>&1 < /dev/null & echo $! > gtkwave.pid)
    sleep 1
    kill -0 "$(cat "$OUT/gtkwave.pid")" 2>/dev/null || { cat "$OUT/gtkwave.log"; return 1; }
    echo "GTKWave opened: $OUT/axi4lite-memory.gtkw"
}
if [[ "$MODE" == --view ]]; then
    test -L "$BASE/latest" || { echo 'No successful memory debug run yet.' >&2; exit 1; }
    OUT=$(readlink -f "$BASE/latest")
    # Keep previous launch logs as evidence, too.
    OUT_VIEW=$(mktemp -d "$BASE/view.XXXXXX")
    ln -s "$OUT/run" "$OUT_VIEW/run"
    cp "$OUT/axi4lite-memory.gtkw" "$OUT_VIEW/axi4lite-memory.gtkw"
    OUT="$OUT_VIEW"
    open_wave
    exit 0
fi
mkdir -p "$BASE"
OUT=$(mktemp -d "$BASE/run.XXXXXX")
mkdir -p "$OUT/run"
printf 'RUN_DIR=%s\nVCD=%s/run/axi4lite_uvm.vcd\n' "$OUT" "$OUT"
# Validate a small set of selected words and generate read-only, continuous probes.
python3 - "$OUT" "${MEM_WORDS:-4}" <<'PY'
import json
import re
import sys
from pathlib import Path
out = Path(sys.argv[1])
raw = sys.argv[2].split(',')
if not raw or any(not re.fullmatch(r'[0-9]+', x.strip()) for x in raw):
    raise SystemExit('MEM_WORDS must be comma-separated decimal indices, e.g. 4,5')
words = sorted(set(int(x) for x in raw))
if any(x < 0 or x >= 256 for x in words) or len(words) > 16:
    raise SystemExit('Select 1..16 memory words with indices 0..255')
(out / 'words.json').write_text(json.dumps(words) + '\n')
(out / 'axi4lite_debug_probes.svh').write_text(
    '// Generated debug-only read probes. Never drive DUT storage.\n' +
    ''.join(f'wire [31:0] debug_mem{i} = dut.mem[{i}];\n' for i in words))
layout = Path('debug/axi4lite-memory.gtkw').read_text()
layout = layout.replace('tb_top.debug_mem4[31:0]', '\n'.join(f'tb_top.debug_mem{i}[31:0]' for i in words))
(out / 'axi4lite-memory.gtkw').write_text(layout)
PY
# All previous non-debug logs and waves remain byte-for-byte unchanged.
find build -type f \( -name '*.vcd' -o -name '*.log' \) ! -path 'build/uvm-mem-debug/*' -print0 | sort -z | xargs -0 -r sha256sum > "$OUT/prior-results.sha256"
find rtl tb "$UVM_HOME/src" -type f \( -name '*.sv' -o -name '*.svh' \) -print0 | sort -z | xargs -0 sha256sum > "$OUT/sources.sha256"
sha256sum debug/trace-memory.sh debug/check-memory-trace.py debug/axi4lite-memory.gtkw >> "$OUT/sources.sha256"
# Reuse a binary only for identical sources, tools, script and probe selection.
{
    cat "$OUT/sources.sha256" "$OUT/axi4lite_debug_probes.svh"
    "$VERILATOR_ROOT/bin/verilator" --version
    sha256sum "$VERILATOR_ROOT/bin/verilator_bin"
    g++ --version
} > "$OUT/build-inputs.txt"
KEY=$(sha256sum "$OUT/build-inputs.txt" | cut -d ' ' -f1)
CACHE="$BASE/cache/$KEY"
mkdir -p "$CACHE"
(
    flock 9
    if [[ ! -f "$CACHE/complete" || ! -x "$CACHE/obj/uvm_mem_debug_sim" ]]; then
        cp "$OUT/axi4lite_debug_probes.svh" "$CACHE/axi4lite_debug_probes.svh"
        cmd=("$VERILATOR_ROOT/bin/verilator" --binary --timing --assert --trace
             --coverage -Wno-fatal -j 2 +define+UVM_NO_DPI +define+AXI4LITE_DEBUG_PROBES
             "+incdir+$CACHE" "+incdir+$UVM_HOME/src" +incdir+tb
             "$UVM_HOME/src/uvm_pkg.sv" tb/axi4lite_if.sv tb/axi4lite_pkg.sv
             rtl/axi4lite_slave.sv tb/tb_top.sv --top-module tb_top
             --Mdir "$CACHE/obj" -o uvm_mem_debug_sim)
        printf '%q ' "${cmd[@]}" > "$CACHE/compile-command.txt"
        printf '\n' >> "$CACHE/compile-command.txt"
        echo "Compiling: $CACHE/compile.log"
        "${cmd[@]}" > "$CACHE/compile.log" 2>&1
        touch "$CACHE/complete"
    else
        echo "CACHE_HIT=$CACHE/obj/uvm_mem_debug_sim"
    fi
) 9> "$CACHE/build.lock"
ln -s "$CACHE" "$OUT/build"
cp "$CACHE/compile-command.txt" "$OUT/compile-command.txt"
(
    cd "$OUT/run"
    timeout 600s "$CACHE/obj/uvm_mem_debug_sim" +UVM_TESTNAME=axi4lite_regression_test +verilator+seed+20261022 > simulator.log 2>&1
)
grep -Eq 'UVM_ERROR[[:space:]]*:[[:space:]]*0' "$OUT/run/simulator.log"
grep -Eq 'UVM_FATAL[[:space:]]*:[[:space:]]*0' "$OUT/run/simulator.log"
grep -q 'RESULT: PASS' "$OUT/run/simulator.log"
python3 debug/check-memory-trace.py "$OUT"
sha256sum --check --status "$OUT/sources.sha256"
sha256sum --check --status "$OUT/prior-results.sha256"
printf 'SOURCE_AND_PRIOR_RESULTS_UNCHANGED=PASS\nVCD=%s/run/axi4lite_uvm.vcd\nLAYOUT=%s/axi4lite-memory.gtkw\n' "$OUT" "$OUT" | tee "$OUT/result.txt"
ln -sfn "$(basename "$OUT")" "$BASE/latest"
if [[ "$MODE" != --no-gui ]]; then open_wave; fi
