// =============================================================================
// File:    rr_read_arbiter.sv
//
// Module Description:
//   Round-robin read arbiter: NUM_CORES requesters share one BRAM read port.
//   Grants are pipelined by BRAM_LATENCY cycles before asserting resp_valid.
//
// Protocol:
//   req_valid/req_ready: combinational grant. resp_valid: BRAM_LATENCY cycles later.
// =============================================================================
`timescale 1ns/1ns

module rr_read_arbiter #(
    parameter DATA_WIDTH   = 16,
    parameter ADDR_WIDTH   = 16,
    parameter NUM_CORES    = 4,
    parameter BRAM_LATENCY = 1     // cycles from grant to valid read data
)(
    input  logic                   clk,
    input  logic                   rst,

    // Core-side request/response, one slot per core
    input  logic [NUM_CORES-1:0]   req_valid,
    input  logic [ADDR_WIDTH-1:0]  req_addr   [NUM_CORES-1:0],
    output logic [NUM_CORES-1:0]   req_ready,
    output logic [NUM_CORES-1:0]   resp_valid,
    output logic [DATA_WIDTH-1:0]  resp_data  [NUM_CORES-1:0],

    // BRAM-side single read port
    output logic [ADDR_WIDTH-1:0]  bram_addr,
    output logic                   bram_rd_en,
    input  logic [DATA_WIDTH-1:0]  bram_rd_data,

    // Debug / fairness counters — one saturating-free 32-bit counter per core
    output logic [31:0]            grant_count [NUM_CORES-1:0],
    output logic [31:0]            stall_cycles
);

    localparam PTR_W = (NUM_CORES == 1) ? 1 : $clog2(NUM_CORES);

    logic [PTR_W-1:0]     ptr;
    logic [NUM_CORES-1:0] grant;

    // Combinational round-robin scan starting at ptr, wrap via modulo.
    // First requester found (starting from ptr) wins this cycle.
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

    assign req_ready  = grant;
    assign bram_rd_en = |req_valid;

    // Winning core's address drives the shared BRAM port
    always_comb begin
        bram_addr = '0;
        for (int i = 0; i < NUM_CORES; i++)
            if (grant[i]) bram_addr = req_addr[i];
    end

    // BRAM_LATENCY cycles later, resp_valid points at whoever was granted
    // BRAM_LATENCY cycles ago — this lines up with the BRAM's actual
    // grant-to-valid-data latency (1 for dual_port_bram, 2 for the real
    // altsyncram-based matrix_ab IP). grant_pipe[0] is the live grant;
    // grant_pipe[BRAM_LATENCY] is what drives resp_valid. With
    // BRAM_LATENCY=1 this is identical to the previous single-register
    // grant_d behavior.
    logic [NUM_CORES-1:0] grant_pipe [BRAM_LATENCY:0];
    assign grant_pipe[0] = grant;

    genvar gl;
    generate
        for (gl = 0; gl < BRAM_LATENCY; gl++) begin : g_latency
            always_ff @(posedge clk or posedge rst) begin
                if (rst) grant_pipe[gl+1] <= '0;
                else     grant_pipe[gl+1] <= grant_pipe[gl];
            end
        end
    endgenerate

    assign resp_valid = grant_pipe[BRAM_LATENCY];

    genvar gi;
    generate
        for (gi = 0; gi < NUM_CORES; gi++) begin : g_resp
            assign resp_data[gi] = bram_rd_data;
        end
    endgenerate

    // ── Debug counters ──────────────────────────────────────────────────
    generate
        for (gi = 0; gi < NUM_CORES; gi++) begin : g_cnt
            always_ff @(posedge clk or posedge rst) begin
                if (rst)            grant_count[gi] <= 32'd0;
                else if (grant[gi]) grant_count[gi] <= grant_count[gi] + 32'd1;
            end
        end
    endgenerate

    // Cycles where at least one core wanted the bus but didn't get it —
    // a direct measure of memory contention.
    always_ff @(posedge clk or posedge rst) begin
        if (rst)
            stall_cycles <= 32'd0;
        else if (|(req_valid & ~grant))
            stall_cycles <= stall_cycles + 32'd1;
    end

endmodule
