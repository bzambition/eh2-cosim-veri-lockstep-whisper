module test_dc
import eh2_pkg::*;
#(
`include "eh2_param_packed.vh"
) (
    input logic [pt.NUM_THREADS-1:0] a,
    output logic [7:0] b
);
    assign b = {8{a[0]}};
endmodule
