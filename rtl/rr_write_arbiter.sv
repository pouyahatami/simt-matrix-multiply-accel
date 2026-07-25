// =============================================================================
// File:    rr_write_arbiter.sv
//
// Module Description:
//   Round-robin write arbiter: NUM_CORES requesters share one BRAM write port.
//   Writes commit in the same cycle they are granted (no response latency).
//
// Protocol:
//   req_valid/req_ready: combinational grant; no resp path needed for writes.
// =============================================================================
`timescale 1ns/1ns

module rr_write_arbiter #(
    parameter DATA_WIDTH = 16,
    parameter ADDR_WIDTH = 16,
    parameter NUM_CORES  = 4
)(
    input  logic                   clk,
    input  logic                   rst,

    input  logic [NUM_CORES-1:0]   req_valid,
    input  logic [ADDR_WIDTH-1:0]  req_addr   [NUM_CORES-1:0],
    input  logic [DATA_WIDTH-1:0]  req_data   [NUM_CORES-1:0],
    output logic [NUM_CORES-1:0]   req_ready,

    output logic [ADDR_WIDTH-1:0]  bram_addr,
    output logic [DATA_WIDTH-1:0]  bram_wr_data,
    output logic                   bram_wr_en,

    output logic [31:0]            grant_count [NUM_CORES-1:0],
    output logic [31:0]            stall_cycles
);

    localparam PTR_W = (NUM_CORES == 1) ? 1 : $clog2(NUM_CORES);

    logic [PTR_W-1:0]     ptr;
    logic [NUM_CORES-1:0] grant;

    always_comb begin
        grant = '0;
        for (int i = 0; i < NUM_CORES; i++) begin
            automatic int idx = (int'(ptr) + i) % NUM_CORES;
            if (req_valid[idx] && grant == '0)
                grant[idx] = 1'b1;
        end
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            ptr <= '0;
        end else if (grant != '0) begin
            for (int i = 0; i < NUM_CORES; i++)
                if (grant[i]) ptr <= PTR_W'((i + 1) % NUM_CORES);
        end
    end

    assign req_ready   = grant;
    assign bram_wr_en  = |grant;

    always_comb begin
        bram_addr    = '0;
        bram_wr_data = '0;
        for (int i = 0; i < NUM_CORES; i++) begin
            if (grant[i]) begin
                bram_addr    = req_addr[i];
                bram_wr_data = req_data[i];
            end
        end
    end

    genvar gi;
    generate
        for (gi = 0; gi < NUM_CORES; gi++) begin : g_cnt
            always_ff @(posedge clk or posedge rst) begin
                if (rst)            grant_count[gi] <= 32'd0;
                else if (grant[gi]) grant_count[gi] <= grant_count[gi] + 32'd1;
            end
        end
    endgenerate

    always_ff @(posedge clk or posedge rst) begin
        if (rst)
            stall_cycles <= 32'd0;
        else if (|(req_valid & ~grant))
            stall_cycles <= stall_cycles + 32'd1;
    end

endmodule
