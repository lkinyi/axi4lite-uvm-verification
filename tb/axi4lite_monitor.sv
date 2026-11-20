//==============================================================================
// axi4lite_monitor.sv
// UVM monitor: observes completed AXI4-Lite transactions on the bus and
// broadcasts reconstructed transactions through an analysis port.
//==============================================================================
class axi4lite_monitor extends uvm_monitor;
    `uvm_component_utils(axi4lite_monitor)

    virtual axi4lite_if vif;
    uvm_analysis_port #(axi4lite_seq_item) ap;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        ap = new("ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db#(virtual axi4lite_if)::get(this, "", "vif", vif))
            `uvm_fatal("MON", "virtual interface not set for monitor")
    endfunction

    task run_phase(uvm_phase phase);
        @(posedge vif.aresetn);
        fork
            monitor_writes();
            monitor_reads();
        join
    endtask

    //--------------------------------------------------------------------------
    // Reconstruct a write from the AW + W handshakes, publish at B handshake.
    //--------------------------------------------------------------------------
    task monitor_writes();
        forever begin
            bit [31:0] a, d;
            bit [3:0] s;
            bit got_aw = 0, got_w = 0;
            bit aw_hs, w_hs;
            int unsigned stalls = 0;
            axi4lite_seq_item::aw_w_order_e order = axi4lite_seq_item::AW_W_UNKNOWN;
            // One #1step clocking-block sample per edge, through the B handshake.
            // Test both handshakes before updating got_aw/got_w: simultaneous
            // acceptance must not accidentally become AW-first.
            forever begin
                @(vif.mon_cb);
                aw_hs = vif.mon_cb.awvalid && vif.mon_cb.awready && !got_aw;
                w_hs  = vif.mon_cb.wvalid  && vif.mon_cb.wready  && !got_w;
                if (!got_aw && !got_w) begin
                    if (aw_hs && w_hs) order = axi4lite_seq_item::SAME_CYCLE;
                    else if (aw_hs)    order = axi4lite_seq_item::AW_FIRST;
                    else if (w_hs)     order = axi4lite_seq_item::W_FIRST;
                end
                if (aw_hs) begin a = vif.mon_cb.awaddr; got_aw = 1; end
                if (w_hs) begin
                    d = vif.mon_cb.wdata; s = vif.mon_cb.wstrb; got_w = 1;
                end
                // Count the first stalled BVALID sample, exclude idle cycles
                // and the final BVALID && BREADY handshake sample.
                if (vif.mon_cb.bvalid && !vif.mon_cb.bready) stalls++;
                if (got_aw && got_w && vif.mon_cb.bvalid && vif.mon_cb.bready)
                    break;
            end
            begin
                axi4lite_seq_item tr = axi4lite_seq_item::type_id::create("mon_wr");
                tr.dir = axi4lite_seq_item::AXI_WRITE;
                tr.addr = a; tr.data = d; tr.strb = s; tr.resp = vif.mon_cb.bresp;
                tr.aw_w_order = order;
                tr.b_stall_cycles = stalls;
                if ($test$plusargs("AXI_COV_TRACE"))
                    `uvm_info("COV_WRITE", $sformatf(
                        "addr=%08h order=%s b_stalls=%0d", a, order.name(), stalls), UVM_LOW)
                ap.write(tr);
            end
        end
    endtask

    //--------------------------------------------------------------------------
    // Reconstruct a read from the AR handshake + R handshake.
    //--------------------------------------------------------------------------
    task monitor_reads();
        forever begin
            bit [31:0] a;
            do @(vif.mon_cb); while (!(vif.mon_cb.arvalid && vif.mon_cb.arready));
            a = vif.mon_cb.araddr;
            do @(vif.mon_cb); while (!(vif.mon_cb.rvalid && vif.mon_cb.rready));
            begin
                axi4lite_seq_item tr = axi4lite_seq_item::type_id::create("mon_rd");
                tr.dir = axi4lite_seq_item::AXI_READ;
                tr.addr = a; tr.data = vif.mon_cb.rdata; tr.strb = 4'h0;
                tr.resp = vif.mon_cb.rresp;
                ap.write(tr);
            end
        end
    endtask

endclass
