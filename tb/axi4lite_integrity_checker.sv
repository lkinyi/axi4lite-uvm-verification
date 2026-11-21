// Reconcile completed Driver records, Monitor publications and Scoreboard counts.
// The Driver is a completion-record reference, NOT independent bus truth.
// Ordered per-direction queues suit the existing serial active Driver only.
// No request-acceptance, outstanding tracking or mid-test reset recovery here.
`uvm_analysis_imp_decl(_completed)
`uvm_analysis_imp_decl(_observed)

class axi4lite_integrity_checker extends uvm_component;
    `uvm_component_utils(axi4lite_integrity_checker)

    uvm_analysis_imp_completed #(axi4lite_seq_item, axi4lite_integrity_checker) driver_imp;
    uvm_analysis_imp_observed #(axi4lite_seq_item, axi4lite_integrity_checker) monitor_imp;
    axi4lite_scoreboard sb;
    bit active_check;
    local axi4lite_seq_item driver_writes[$], driver_reads[$];
    local axi4lite_seq_item monitor_writes[$], monitor_reads[$];
    local int unsigned integrity_errors;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        driver_imp = new("driver_imp", this);
        monitor_imp = new("monitor_imp", this);
    endfunction

    // Snapshot on receipt too: a publisher may reuse or modify its source later.
    function void write_completed(axi4lite_seq_item tr);
        axi4lite_seq_item snapshot = axi4lite_seq_item::type_id::create("driver_snapshot");
        snapshot.copy(tr);
        if (snapshot.dir == axi4lite_seq_item::AXI_WRITE) driver_writes.push_back(snapshot);
        else driver_reads.push_back(snapshot);
    endfunction

    function void write_observed(axi4lite_seq_item tr);
        axi4lite_seq_item snapshot = axi4lite_seq_item::type_id::create("monitor_snapshot");
        snapshot.copy(tr);
        if (snapshot.dir == axi4lite_seq_item::AXI_WRITE) monitor_writes.push_back(snapshot);
        else monitor_reads.push_back(snapshot);
    endfunction

    function void fail(string message);
        integrity_errors++;
        `uvm_error("TXN_INTEGRITY", message)
    endfunction

    // Explicit contents, never class-handle inequality. Read strobes and
    // stimulus delays / coverage metadata deliberately do not participate.
    function void compare_stream(string kind, ref axi4lite_seq_item expected[$],
                                 ref axi4lite_seq_item observed[$]);
        int n = (expected.size() < observed.size()) ? expected.size() : observed.size();
        if (observed.size() < expected.size())
            fail($sformatf("MISSING_MON_%s driver=%0d monitor=%0d missing=%0d",
                 kind, expected.size(), observed.size(), expected.size()-observed.size()));
        if (observed.size() > expected.size())
            fail($sformatf("EXTRA_MON_%s duplicate/extra publication driver=%0d monitor=%0d extra=%0d",
                 kind, expected.size(), observed.size(), observed.size()-expected.size()));
        for (int i = 0; i < n; i++) begin
            string fields = "";
            if (expected[i].dir !== observed[i].dir) fields = {fields, " dir"};
            if (expected[i].addr !== observed[i].addr) fields = {fields, " addr"};
            if (expected[i].data !== observed[i].data) fields = {fields, " data"};
            if (expected[i].resp !== observed[i].resp) fields = {fields, " resp"};
            if (expected[i].dir == axi4lite_seq_item::AXI_WRITE &&
                expected[i].strb !== observed[i].strb) fields = {fields, " strb"};
            if (fields != "")
                fail($sformatf("FIELD_MISMATCH_%s index=%0d fields=%s driver={%s} monitor={%s}",
                     kind, i, fields, expected[i].convert2string(), observed[i].convert2string()));
        end
    endfunction

    function void check_phase(uvm_phase phase);
        super.check_phase(phase);
        if (sb == null) begin
            fail("SCB_UNCONNECTED scoreboard handle missing");
            return;
        end
        `uvm_info("TXN_INTEGRITY", $sformatf(
            "COUNTS active=%0d driver_writes=%0d driver_reads=%0d monitor_writes=%0d monitor_reads=%0d scoreboard_writes=%0d scoreboard_reads=%0d",
            active_check, driver_writes.size(), driver_reads.size(),
            monitor_writes.size(), monitor_reads.size(), sb.writes, sb.reads), UVM_LOW)
        if (sb.writes != monitor_writes.size() || sb.reads != monitor_reads.size())
            fail($sformatf("SCB_MON_COUNT monitor=(%0d,%0d) scoreboard=(%0d,%0d)",
                 monitor_writes.size(), monitor_reads.size(), sb.writes, sb.reads));
        if (!active_check) begin
            `uvm_info("TXN_INTEGRITY", "RESULT: SKIP_ACTIVE passive agent; no Driver/Monitor reconciliation (Monitor/Scoreboard counts checked only)", UVM_LOW)
            return;
        end
        compare_stream("WRITE", driver_writes, monitor_writes);
        compare_stream("READ", driver_reads, monitor_reads);
        if (sb.writes != driver_writes.size() || sb.reads != driver_reads.size())
            fail($sformatf("SCB_DRIVER_COUNT driver=(%0d,%0d) scoreboard=(%0d,%0d)",
                 driver_writes.size(), driver_reads.size(), sb.writes, sb.reads));
        if (integrity_errors == 0)
            `uvm_info("TXN_INTEGRITY", "RESULT: PASS completed-record consistency only", UVM_LOW)
        else
            `uvm_info("TXN_INTEGRITY", $sformatf("RESULT: FAIL errors=%0d", integrity_errors), UVM_LOW)
    endfunction
endclass
