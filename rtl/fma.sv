// =============================================================================
// File:    fma.sv
//
// Module Description:
//   Pipelined fused multiply-accumulate: result = (a * b) + c
//   One cycle latency; valid_in/valid_out handshake.
// =============================================================================
module fma #(
    parameter DATA_WIDTH = 16
)(
    input logic clk, rst,
    input logic [DATA_WIDTH-1:0] a, b, c,
    input logic valid_in,

    output logic [DATA_WIDTH-1:0] result,
    output logic valid_out
);

    logic [2*DATA_WIDTH-1:0] product;
    logic [DATA_WIDTH-1:0] product_aligned;

    assign product = a * b;
    assign product_aligned = product[DATA_WIDTH-1:0];

    always_ff @(posedge clk) begin
        if (rst) begin
            result <= 0;
            valid_out <= 0;
        end else begin
            valid_out <= valid_in;
            if (valid_in) result <= product_aligned + c;
        end
    end

endmodule