//==============================================================================
// axi4lite_test.sv
// Test library. Base test builds the env; derived tests pick a sequence.
//==============================================================================
class axi4lite_base_test extends uvm_test;
    `uvm_component_utils(axi4lite_base_test)

    axi4lite_env env;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        env = axi4lite_env::type_id::create("env", this);
    endfunction

    // Drop objection after the chosen sequence finishes (overridden below)
    virtual task run_phase(uvm_phase phase); endtask
endclass

//------------------------------------------------------------------------------
// Smoke / sanity: directed write-read pairs.
//------------------------------------------------------------------------------
class axi4lite_sanity_test extends axi4lite_base_test;
    `uvm_component_utils(axi4lite_sanity_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    task run_phase(uvm_phase phase);
        axi4lite_write_read_seq seq = axi4lite_write_read_seq::type_id::create("seq");
        phase.raise_objection(this);
        assert(seq.randomize() with { num_pairs == 10; });
        seq.start(env.agent.sqr);
        phase.phase_done.set_drain_time(this, 100ns);
        phase.drop_objection(this);
    endtask
endclass

//------------------------------------------------------------------------------
// Regression: directed corner cases + constrained-random traffic + readbacks,
// to push functional coverage up. This is the default test.
//------------------------------------------------------------------------------
class axi4lite_regression_test extends axi4lite_base_test;
    `uvm_component_utils(axi4lite_regression_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    task run_phase(uvm_phase phase);
        axi4lite_timing_seq timing_seq=axi4lite_timing_seq::type_id::create("timing_seq");
        axi4lite_init_seq init_seq = axi4lite_init_seq::type_id::create("init_seq");
        axi4lite_directed_seq   d_seq   = axi4lite_directed_seq::type_id::create("d_seq");
        axi4lite_write_read_seq wr_seq  = axi4lite_write_read_seq::type_id::create("wr_seq");
        axi4lite_random_seq     rnd_seq = axi4lite_random_seq::type_id::create("rnd_seq");
        axi4lite_error_seq      err_seq = axi4lite_error_seq::type_id::create("err_seq");

        phase.raise_objection(this);
        init_seq.start(env.agent.sqr);
        d_seq.start(env.agent.sqr);
        timing_seq.start(env.agent.sqr);
        assert(wr_seq.randomize() with { num_pairs == 16; });
        wr_seq.start(env.agent.sqr);
        assert(rnd_seq.randomize() with { num_txns == 40; });
        rnd_seq.start(env.agent.sqr);
        assert(err_seq.randomize() with {num_txns == 12;});
        err_seq.start(env.agent.sqr);          // out-of-range -> DECERR error path
        phase.phase_done.set_drain_time(this, 200ns);
        phase.drop_objection(this);
    endtask
endclass

//------------------------------------------------------------------------------
// RAL test: access the slave memory through the register-abstraction layer
// (regmodel.mem.write/read) instead of hand-driving addresses.
// Run with +UVM_TESTNAME=axi4lite_ral_test
//------------------------------------------------------------------------------
class axi4lite_ral_test extends axi4lite_base_test;
    `uvm_component_utils(axi4lite_ral_test)

    axi4lite_reg_block   regmodel;
    axi4lite_reg_adapter adapter;

    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);                 // builds env (agent/scoreboard/cov)
        regmodel = axi4lite_reg_block::type_id::create("regmodel");
        regmodel.build();                          // configures uvm_mem + locks model
    endfunction

    function void connect_phase(uvm_phase phase);
        adapter = axi4lite_reg_adapter::type_id::create("adapter");
        regmodel.default_map.set_sequencer(env.agent.sqr, adapter);
    endfunction

    task run_phase(uvm_phase phase);
        uvm_status_e   status;
        uvm_reg_data_t rdata;
        phase.raise_objection(this);
        for (int i = 0; i < 8; i++) begin
            regmodel.mem.write(status, i, 32'hA000_0000 + i, .parent(null));
            if(status != UVM_IS_OK) `uvm_fatal("RAL", "write status failure")
            regmodel.mem.read (status, i, rdata,            .parent(null));
            if(status != UVM_IS_OK) `uvm_fatal("RAL", "read status failure")
            if (rdata !== (32'hA000_0000 + i))
                `uvm_error("RAL", $sformatf("mem[%0d] expected 0x%08h got 0x%08h",
                           i, 32'hA000_0000 + i, rdata))
            else
                `uvm_info("RAL", $sformatf("mem[%0d] OK = 0x%08h", i, rdata), UVM_LOW)
        end
        phase.phase_done.set_drain_time(this, 200ns);
        phase.drop_objection(this);
    endtask
endclass


// Zero-stall acceptance check. The normal driver waits for BVALID before
// asserting BREADY, so its minimum observed stall is one cycle.
class axi4lite_zero_stall_test extends axi4lite_base_test;
    `uvm_component_utils(axi4lite_zero_stall_test)
    virtual axi4lite_if vif;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    function void build_phase(uvm_phase phase);
        uvm_config_db#(uvm_active_passive_enum)::set(this, "env.agent", "is_active", UVM_PASSIVE);
        super.build_phase(phase);
        if (!uvm_config_db#(virtual axi4lite_if)::get(this, "", "vif", vif))
            `uvm_fatal("ZERO_STALL", "virtual interface missing")
    endfunction

    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        vif.drv_cb.awvalid <= 0; vif.drv_cb.wvalid <= 0;
        vif.drv_cb.arvalid <= 0; vif.drv_cb.rready <= 0;
        vif.drv_cb.bready <= 0;
        vif.drv_cb.awaddr <= 0; vif.drv_cb.wdata <= 0;
        vif.drv_cb.wstrb <= 0; vif.drv_cb.araddr <= 0;
        @(posedge vif.aresetn);
        @(vif.drv_cb);
        vif.drv_cb.bready <= 1;
        vif.drv_cb.awaddr <= 32'h20; vif.drv_cb.awvalid <= 1;
        do @(vif.drv_cb); while (!vif.drv_cb.awready);
        vif.drv_cb.awvalid <= 0;
        repeat (6) @(vif.drv_cb);
        vif.drv_cb.wdata <= 32'h12345678; vif.drv_cb.wstrb <= 15;
        vif.drv_cb.wvalid <= 1;
        do @(vif.drv_cb); while (!vif.drv_cb.wready);
        vif.drv_cb.wvalid <= 0;
        do @(vif.drv_cb); while (!vif.drv_cb.bvalid);
        vif.drv_cb.bready <= 0;
        vif.drv_cb.araddr <= 32'h20; vif.drv_cb.arvalid <= 1;
        do @(vif.drv_cb); while (!vif.drv_cb.arready);
        vif.drv_cb.arvalid <= 0;
        vif.drv_cb.rready <= 1;
        do @(vif.drv_cb); while (!vif.drv_cb.rvalid);
        vif.drv_cb.rready <= 0;
        phase.phase_done.set_drain_time(this, 100ns);
        phase.drop_objection(this);
    endtask
endclass

// Plan A tests use the unchanged active agent and its existing checking path.
class axi4lite_decerr_alias_test extends axi4lite_base_test;
    `uvm_component_utils(axi4lite_decerr_alias_test)
    int unsigned case_id = 0;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
        axi4lite_decerr_alias_seq seq = axi4lite_decerr_alias_seq::type_id::create("seq");
        phase.raise_objection(this);
        seq.case_id = case_id;
        seq.start(env.agent.sqr);
        phase.phase_done.set_drain_time(this, 100ns);
        phase.drop_objection(this);
    endtask
endclass

class axi4lite_decerr_top_test extends axi4lite_decerr_alias_test;
    `uvm_component_utils(axi4lite_decerr_top_test)
    function new(string name, uvm_component parent);
        super.new(name, parent); case_id = 1;
    endfunction
endclass

class axi4lite_decerr_partial_test extends axi4lite_decerr_alias_test;
    `uvm_component_utils(axi4lite_decerr_partial_test)
    function new(string name, uvm_component parent);
        super.new(name, parent); case_id = 2;
    endfunction
endclass
