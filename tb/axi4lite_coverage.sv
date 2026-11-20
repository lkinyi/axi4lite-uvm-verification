//==============================================================================
// axi4lite_coverage.sv
// Functional coverage subscriber: real covergroups over operation, address
// range, byte-strobe pattern, and operation x address-range cross.
//==============================================================================
class axi4lite_coverage extends uvm_subscriber #(axi4lite_seq_item);
    `uvm_component_utils(axi4lite_coverage)

    axi4lite_seq_item tr;
    // Portable exact hit counts alongside the simulator's native covergroup.
    int unsigned aw_first_hits, w_first_hits, same_cycle_hits;
    int unsigned b_zero_hits, b_short_hits, b_long_hits;

    covergroup cg_axi;
        option.per_instance = 1;

        cp_dir : coverpoint tr.dir {
            bins write = {axi4lite_seq_item::AXI_WRITE};
            bins read  = {axi4lite_seq_item::AXI_READ};
        }

        cp_addr_range : coverpoint tr.addr {
            bins low  = {[32'h0000_0000 : 32'h0000_00FC]};
            bins mid  = {[32'h0000_0100 : 32'h0000_02FC]};
            bins high = {[32'h0000_0300 : 32'h0000_03FC]};
            bins oob  = {[32'h0000_0400 : 32'h0000_FFFC]};   // out-of-range (DECERR)
        }

        cp_strb : coverpoint tr.strb iff (tr.dir == axi4lite_seq_item::AXI_WRITE) {
            bins full   = {4'hF};
            bins single = {4'h1, 4'h2, 4'h4, 4'h8};
            bins other  = default;
        }

        cp_resp : coverpoint tr.resp {
            bins okay   = {2'b00};
            bins decerr = {2'b11};
        }

        cp_aw_w_order : coverpoint tr.aw_w_order
            iff (tr.dir == axi4lite_seq_item::AXI_WRITE) {
            bins aw_first   = {axi4lite_seq_item::AW_FIRST};
            bins w_first    = {axi4lite_seq_item::W_FIRST};
            bins same_cycle = {axi4lite_seq_item::SAME_CYCLE};
        }

        cp_b_stall : coverpoint tr.b_stall_cycles
            iff (tr.dir == axi4lite_seq_item::AXI_WRITE) {
            bins zero  = {0};
            bins short = {[1:2]};
            bins long_stall = {[3:$]};
        }

        x_dir_range : cross cp_dir, cp_addr_range;
    endgroup

    function new(string name, uvm_component parent);
        super.new(name, parent);
        cg_axi = new();
    endfunction

    // uvm_subscriber requires this single write() hook
    function void write(axi4lite_seq_item t);
        tr = t;
        cg_axi.sample();
        if (t.dir == axi4lite_seq_item::AXI_WRITE) begin
            case (t.aw_w_order)
                axi4lite_seq_item::AW_FIRST:   aw_first_hits++;
                axi4lite_seq_item::W_FIRST:    w_first_hits++;
                axi4lite_seq_item::SAME_CYCLE: same_cycle_hits++;
                default: `uvm_error("COV", "Write missing observed AW/W order")
            endcase
            if (t.b_stall_cycles == 0) b_zero_hits++;
            else if (t.b_stall_cycles <= 2) b_short_hits++;
            else b_long_hits++;
        end
    endfunction

    function void report_phase(uvm_phase phase);
        `uvm_info("COV_BINS", $sformatf(
            "aw_first=%0d w_first=%0d same_cycle=%0d zero=%0d short=%0d long_stall=%0d",
            aw_first_hits, w_first_hits, same_cycle_hits,
            b_zero_hits, b_short_hits, b_long_hits), UVM_LOW)
        `uvm_info("COV", $sformatf("Functional coverage = %0.2f%%",
                  cg_axi.get_inst_coverage()), UVM_LOW)
    endfunction

endclass
