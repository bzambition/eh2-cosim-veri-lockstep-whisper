package test_pkg;
    typedef struct packed {
        bit [4:0] WIDTH_A;
        bit [7:0] WIDTH_B;
    } param_t;

    parameter param_t cfg = 13'h0ABC;
endpackage

module test_mod (
    input  logic [test_pkg::cfg.WIDTH_A-1:0] a_in,
    output logic [test_pkg::cfg.WIDTH_B-1:0] b_out
);
    assign b_out = { {3{1'b0}}, a_in };
endmodule
