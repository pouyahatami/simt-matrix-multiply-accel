// =============================================================================
// File:    dual_port_bram.sv
//
// Module Description:
//   Synchronous true dual-port BRAM, one cycle read latency.
//   Simulation model used by gpu_top_tb; synthesis target is the Quartus IP.
// =============================================================================
//
// This module is the architectural pivot that lets two cores share one
// physical BRAM with zero arbitration: each core gets one of the two
// physical ports the M10K provides.
// =============================================================================
`timescale 1ns/1ps

module dual_port_bram #(
    parameter DATA_WIDTH = 16,
    parameter ADDR_WIDTH = 16,    // width of the address inputs; matches gpu_top's bus width
    parameter DEPTH      = 256    // actual number of words; address is sliced to $clog2(DEPTH) bits
) (
    input  logic                  clk,

    // Port A
    input  logic [ADDR_WIDTH-1:0] a_addr,
    input  logic                  a_wr_en,
    input  logic [DATA_WIDTH-1:0] a_wr_data,
    output logic [DATA_WIDTH-1:0] a_rd_data,

    // Port B
    input  logic [ADDR_WIDTH-1:0] b_addr,
    input  logic                  b_wr_en,
    input  logic [DATA_WIDTH-1:0] b_wr_data,
    output logic [DATA_WIDTH-1:0] b_rd_data
);

    localparam IDX_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH);

    // Exposed at module scope so testbenches can initialise via
    // `<inst>.mem[i] = value;` hierarchical references.
    (* ramstyle = "M10K" *) logic [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    // Port A: write on rising edge, read with one cycle of latency
    always_ff @(posedge clk) begin
        if (a_wr_en) mem[a_addr[IDX_W-1:0]] <= a_wr_data;
        a_rd_data <= mem[a_addr[IDX_W-1:0]];
    end

    // Port B: independent — separate address, write enable, read latch
    always_ff @(posedge clk) begin
        if (b_wr_en) mem[b_addr[IDX_W-1:0]] <= b_wr_data;
        b_rd_data <= mem[b_addr[IDX_W-1:0]];
    end

endmodule
