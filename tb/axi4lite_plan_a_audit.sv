// Optional read-only acceptance sampler; compile explicitly, never drive DUT.
// Existing accept-coverage.py consumes the original columns; extra columns
// provide independent address/data/response evidence for the Plan A mutation.
`timescale 1ns/1ps
module axi4lite_plan_a_audit(axi4lite_if bus);
    integer fd;
    longint unsigned cycle = 0;
    initial begin
        fd = $fopen("bus.csv", "w");
        $fdisplay(fd, "cycle,resetn,awvalid,awready,awaddr,wvalid,wready,bvalid,bready,wdata,wstrb,bresp,arvalid,arready,araddr,rvalid,rready,rdata,rresp");
    end
    always @(posedge bus.aclk) begin
        cycle = cycle + 1;
        $fdisplay(fd, "%0d,%0b,%0b,%0b,%08h,%0b,%0b,%0b,%0b,%08h,%h,%0d,%0b,%0b,%08h,%0b,%0b,%08h,%0d", cycle,
            bus.aresetn, bus.awvalid, bus.awready, bus.awaddr,
            bus.wvalid, bus.wready, bus.bvalid, bus.bready,
            bus.wdata, bus.wstrb, bus.bresp, bus.arvalid, bus.arready,
            bus.araddr, bus.rvalid, bus.rready, bus.rdata, bus.rresp);
    end
    final $fclose(fd);
endmodule
bind tb_top axi4lite_plan_a_audit plan_a_audit(intf);
