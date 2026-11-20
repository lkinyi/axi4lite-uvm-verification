`timescale 1ns/1ps
// Observe the unchanged protocol test and real DUT. No signal is driven here.
module tb_protocol_wave;
  tb_protocol protocol();
  initial begin
    $dumpfile("build/day15/waves/axi4lite_protocol.vcd");
    // Top-level AXI signals only; avoid dumping the DUT memory array.
    $dumpvars(1, tb_protocol_wave.protocol);
  end
endmodule
