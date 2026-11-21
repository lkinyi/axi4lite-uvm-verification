//==============================================================================
// axi4lite_driver.sv
// UVM driver: converts transactions into AXI4-Lite pin wiggles.
//==============================================================================
class axi4lite_driver extends uvm_driver #(axi4lite_seq_item);
    `uvm_component_utils(axi4lite_driver)

    virtual axi4lite_if vif;
    uvm_analysis_port #(axi4lite_seq_item) completed_ap;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        completed_ap = new("completed_ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db#(virtual axi4lite_if)::get(this, "", "vif", vif))
            `uvm_fatal("DRV", "virtual interface not set for driver")
    endfunction

    task run_phase(uvm_phase phase);
        // idle the master signals out of reset
        reset_signals();
        @(posedge vif.aresetn);
        @(vif.drv_cb);
        forever begin
            axi4lite_seq_item tr;
            seq_item_port.get_next_item(tr);
            if (tr.dir == axi4lite_seq_item::AXI_WRITE) drive_write(tr);
            else                                        drive_read(tr);
            publish_completed(tr);
            seq_item_port.item_done();
        end
    endtask

    task reset_signals();
        vif.drv_cb.awvalid <= 1'b0;
        vif.drv_cb.wvalid  <= 1'b0;
        vif.drv_cb.bready  <= 1'b0;
        vif.drv_cb.arvalid <= 1'b0;
        vif.drv_cb.rready  <= 1'b0;
        vif.drv_cb.awaddr  <= '0;
        vif.drv_cb.wdata   <= '0;
        vif.drv_cb.wstrb   <= '0;
        vif.drv_cb.araddr  <= '0;
    endtask

    //--------------------------------------------------------------------------
    // AXI4-Lite write: drive AW and W concurrently, then accept B response.
    //--------------------------------------------------------------------------
    task drive_write(axi4lite_seq_item tr);
        // AW and W are independent; hold BREADY low until the response is observed.
        vif.drv_cb.bready <= 0;
        fork
            begin
                repeat(tr.aw_delay) @(vif.drv_cb);
                vif.drv_cb.awaddr <= tr.addr;
                vif.drv_cb.awvalid <= 1;
                do @(vif.drv_cb); while(!vif.drv_cb.awready);
                vif.drv_cb.awvalid <= 0;
            end
            begin
                repeat(tr.w_delay) @(vif.drv_cb);
                vif.drv_cb.wdata <= tr.data;
                vif.drv_cb.wstrb <= tr.strb;
                vif.drv_cb.wvalid <= 1;
                do @(vif.drv_cb); while(!vif.drv_cb.wready);
                vif.drv_cb.wvalid <= 0;
            end
        join
        do @(vif.drv_cb); while(!vif.drv_cb.bvalid);
        repeat(tr.b_delay) @(vif.drv_cb);
        vif.drv_cb.bready <= 1;
        // Both clocking blocks sample #1step. Confirm the actual B handshake,
        // not merely BVALID or the scheduling of BREADY.
        do @(vif.drv_cb); while (!(vif.mon_cb.bvalid && vif.mon_cb.bready));
        tr.resp = vif.drv_cb.bresp;
        vif.drv_cb.bready <= 0;
    endtask

    //--------------------------------------------------------------------------
    // AXI4-Lite read: drive AR, then capture R.
    //--------------------------------------------------------------------------
    task drive_read(axi4lite_seq_item tr);
        vif.drv_cb.araddr  <= tr.addr;
        vif.drv_cb.arvalid <= 1'b1;
        vif.drv_cb.rready  <= 1'b0;

        do @(vif.drv_cb); while (!vif.drv_cb.arready);
        vif.drv_cb.arvalid <= 1'b0;

        do @(vif.drv_cb); while (!vif.drv_cb.rvalid);
        repeat(tr.r_delay) @(vif.drv_cb);
        vif.drv_cb.rready <= 1;
        do @(vif.drv_cb); while (!(vif.mon_cb.rvalid && vif.mon_cb.rready));
        tr.data = vif.drv_cb.rdata;     // result from the accepted R beat
        tr.resp = vif.drv_cb.rresp;
        vif.drv_cb.rready <= 1'b0;
    endtask

    // Publish before item_done permits sequence reuse; never expose its handle.
    function void publish_completed(axi4lite_seq_item tr);
        axi4lite_seq_item completed = axi4lite_seq_item::type_id::create("completed");
        completed.copy(tr);
        completed_ap.write(completed);
    endfunction

endclass

