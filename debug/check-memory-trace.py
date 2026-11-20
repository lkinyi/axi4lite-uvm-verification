#!/usr/bin/env python3
"""Check actual VCD contents, selected read probes and loaded-layout names."""
import json
import re
import sys
from pathlib import Path

out = Path(sys.argv[1]).resolve()
words = json.loads((out / 'words.json').read_text())
vcd = out / 'run/axi4lite_uvm.vcd'
scopes, signals, state, frame = [], {}, {}, {}
changes = {i: 0 for i in words}
commits = matches = 0

def bits(value):
    return int(value, 2) if value and all(c in '01' for c in value) else None

def inspect_frame():
    global commits, matches
    if not frame:
        return
    before = state.copy()
    state.update(frame)
    for i in words:
        code = signals[f'tb_top.debug_mem{i}']
        if code in before and state.get(code) != before[code]:
            changes[i] += 1
    clk = signals['tb_top.aclk']
    if 4 in words and before.get(clk) == '0' and state.get(clk) == '1':
        addr = bits(before.get(signals['tb_top.dut.awaddr_q']))
        if before.get(signals['tb_top.dut.do_write']) == '1' and addr == 0x10:
            commits += 1
            data = bits(before.get(signals['tb_top.dut.wdata_q']))
            old = bits(before.get(signals['tb_top.debug_mem4']))
            strb = bits(before.get(signals['tb_top.dut.wstrb_q']))
            if data is not None and old is not None and strb is not None:
                mask = sum(0xff << (8*b) for b in range(4) if strb & (1 << b))
                expected = (old & ~mask) | (data & mask)
                if bits(state.get(signals['tb_top.debug_mem4'])) == expected:
                    matches += 1
    frame.clear()

with vcd.open() as f:
    for line in f:
        parts = line.split()
        if not parts:
            continue
        if parts[0] == '$scope':
            scopes.append(parts[2])
        elif parts[0] == '$upscope':
            scopes.pop()
        elif parts[0] == '$var':
            signals['.'.join(scopes + [parts[4]])] = parts[3]
        elif parts[0] == '$enddefinitions':
            break
    memory_names = [n for n in signals if re.search(r'(^|\.)mem(?:\[|$)', n)]
    assert not memory_names, f'Unexpected direct memory array dump: {memory_names[:5]}'
    probes = sorted(n for n in signals if re.fullmatch(r'tb_top.debug_mem\d+', n))
    assert probes == sorted(f'tb_top.debug_mem{i}' for i in words), probes
    # Ensure every actual trace in the GTKWave preset exists in this VCD.
    layout_names = [line.strip() for line in (out / 'axi4lite-memory.gtkw').read_text().splitlines() if line.startswith('tb_top.')]
    missing = [n for n in layout_names if re.sub(r'\[\d+:\d+\]$', '', n) not in signals]
    assert not missing, f'Preset contains missing signals: {missing}'
    needed = ['tb_top.aclk', 'tb_top.dut.do_write', 'tb_top.dut.awaddr_q', 'tb_top.dut.wdata_q', 'tb_top.dut.wstrb_q'] + probes
    wanted = {signals[n] for n in needed}
    for line in f:
        line = line.strip()
        if not line:
            continue
        if line[0] == '#':
            inspect_frame()
        elif line[0] == 'b':
            value, code = line[1:].split()
            if code in wanted:
                frame[code] = value
        elif line[0] in '01xz' and line[1:] in wanted:
            frame[line[1:]] = line[0]
    inspect_frame()
if 4 in words:
    assert changes[4] > 0, 'debug_mem4 never changed'
    assert commits >= 2 and matches == commits, 'Address 0x10 writes did not match actual probe values'
# Compare stable scoreboard statistics with the preserved original regression.
summary = re.compile(r'writes=\d+ reads=\d+ MATCH=\d+ MISMATCH=\d+ RESP_MISMATCH=\d+')
current = summary.search((out / 'run/simulator.log').read_text())
assert current, 'Missing scoreboard summary'
baseline = Path('build/uvm-trace/run/simulator.log')
if baseline.exists():
    old = summary.search(baseline.read_text())
    assert old and current.group() == old.group(), 'Regression statistics changed'
result = dict(vcd=str(vcd), probes=probes, direct_memory_elements=len(memory_names), probe_changes=changes, address_0x10_commits=commits, matched_commits=matches, layout_signals=len(layout_names), scoreboard=current.group(), uvm_result='PASS')
(out / 'trace-check.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result))
