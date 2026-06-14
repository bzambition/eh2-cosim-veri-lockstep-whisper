package test_pkg;
    typedef logic [7:0] byte_t;
    parameter int WIDTH = 8;
endpackage

module test_mod (
    input test_pkg::byte_t in,
    output test_pkg::byte_t out
);
    assign out = in;
endmodule
