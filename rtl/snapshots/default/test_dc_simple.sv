typedef struct packed {
    logic [4:0] WIDTH_A;
    logic [7:0] WIDTH_B;
} simple_t;

module test_simple
#(
    parameter simple_t cfg = 13'h0ABC
) (
    input logic [7:0] a,
    output logic [7:0] b
);
    assign b = a;
endmodule
