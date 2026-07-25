// =============================================================================
// File:    gpu_top.sv
//
// Module Description:
//   Top-level GPU. Instantiates one dispatcher, NUM_CORES cores, and three
//   round-robin arbiters (A read, B read, C write) for shared BRAM access.
// =============================================================================

module gpu_top #(
    parameter DATA_WIDTH       = 16,
    parameter ADDR_WIDTH       = 16,
    parameter NUM_CORES        = 4,
    parameter THREADS_PER_CORE = 2,
    // Cycles from a read grant to valid data on bram_a/b_rd_data. Default 1
    // matches dual_port_bram (gpu_top_tb's simulation-only memory). The real
    // Quartus altsyncram IP (matrix_ab.v) has 2-cycle latency and can't be
    // configured down to 1 (its BIDIR_DUAL_PORT mode structurally requires
    // a registered address input on both ports) -- de1soc_top overrides
    // this to 2. See rr_read_arbiter.sv for where this is actually used.
    parameter BRAM_READ_LATENCY = 1
)(
    input  logic                   clk,
    input  logic                   rst,
    input  logic                   start,
    input  logic [7:0]             N,
    input  logic [ADDR_WIDTH-1:0]  base_addr_A,
    input  logic [ADDR_WIDTH-1:0]  base_addr_B,
    input  logic [ADDR_WIDTH-1:0]  base_addr_C,

    //Matrix A, B, C BRAM ports
    output logic [ADDR_WIDTH-1:0]  bram_a_addr,
    output logic                   bram_a_rd_en,
    input  logic [DATA_WIDTH-1:0]  bram_a_rd_data,

    output logic [ADDR_WIDTH-1:0]  bram_b_addr,
    output logic                   bram_b_rd_en,
    input  logic [DATA_WIDTH-1:0]  bram_b_rd_data,

    output logic [ADDR_WIDTH-1:0]  bram_c_addr,
    output logic [DATA_WIDTH-1:0]  bram_c_wr_data,
    output logic                   bram_c_wr_en,

    output logic                   done,

    //Debug signals 
    output logic [31:0]            a_grant_count [NUM_CORES-1:0],
    output logic [31:0]            b_grant_count [NUM_CORES-1:0],
    output logic [31:0]            c_grant_count [NUM_CORES-1:0],
    output logic [31:0]            a_stall_cycles,
    output logic [31:0]            b_stall_cycles,
    output logic [31:0]            c_stall_cycles,
    output logic [31:0]            core_stall_cycles [NUM_CORES-1:0]
);

    // Dispatcher <-> Cores wires
    logic [NUM_CORES-1:0]  core_valid;
    logic [NUM_CORES-1:0]  core_start;
    logic [NUM_CORES-1:0]  core_ready;
    logic [NUM_CORES-1:0]  core_done;
    logic [15:0]           core_thread_id    [NUM_CORES-1:0];
    logic [15:0]           core_thread_count [NUM_CORES-1:0];

    // Core <-> arbiter wires (one slot per core, per channel)
    logic [NUM_CORES-1:0]   a_req_valid, a_req_ready, a_resp_valid;
    logic [ADDR_WIDTH-1:0]  a_req_addr  [NUM_CORES-1:0];
    logic [DATA_WIDTH-1:0]  a_resp_data [NUM_CORES-1:0];

    logic [NUM_CORES-1:0]   b_req_valid, b_req_ready, b_resp_valid;
    logic [ADDR_WIDTH-1:0]  b_req_addr  [NUM_CORES-1:0];
    logic [DATA_WIDTH-1:0]  b_resp_data [NUM_CORES-1:0];

    logic [NUM_CORES-1:0]   c_req_valid, c_req_ready;
    logic [ADDR_WIDTH-1:0]  c_req_addr  [NUM_CORES-1:0];
    logic [DATA_WIDTH-1:0]  c_req_data  [NUM_CORES-1:0];

    // Dispatcher
    dispatcher #(
        .NUM_CORES        (NUM_CORES),
        .THREADS_PER_CORE (THREADS_PER_CORE)
    ) dispatcher_instance (
        .clk               (clk),
        .rst               (rst),
        .start             (start),
        .N                 (N),
        .core_done         (core_done),
        .core_ready        (core_ready),
        .core_valid        (core_valid),
        .core_start        (core_start),
        .core_thread_id    (core_thread_id),
        .core_thread_count (core_thread_count),
        .done              (done)
    );

    // Cores
    genvar c;
    generate
        for (c = 0; c < NUM_CORES; c++) begin : gen_cores
            logic [7:0] tcount_byte;
            assign tcount_byte = core_thread_count[c][7:0];

            core #(
                .DATA_WIDTH       (DATA_WIDTH),
                .ADDR_WIDTH       (ADDR_WIDTH),
                .THREADS_PER_CORE (THREADS_PER_CORE)
            ) u_core (
                .clk             (clk),
                .rst             (rst),
                .valid           (core_valid[c]),
                .ready           (core_ready[c]),
                .start           (core_start[c]),
                .thread_id_start (core_thread_id[c]),
                .thread_count    (tcount_byte),
                .N               (N),
                .base_addr_A     (base_addr_A),
                .base_addr_B     (base_addr_B),
                .base_addr_C     (base_addr_C),

                .a_req_valid     (a_req_valid[c]),
                .a_req_addr      (a_req_addr[c]),
                .a_req_ready     (a_req_ready[c]),
                .a_resp_valid    (a_resp_valid[c]),
                .a_resp_data     (a_resp_data[c]),

                .b_req_valid     (b_req_valid[c]),
                .b_req_addr      (b_req_addr[c]),
                .b_req_ready     (b_req_ready[c]),
                .b_resp_valid    (b_resp_valid[c]),
                .b_resp_data     (b_resp_data[c]),

                .c_req_valid     (c_req_valid[c]),
                .c_req_addr      (c_req_addr[c]),
                .c_req_data      (c_req_data[c]),
                .c_req_ready     (c_req_ready[c]),

                .done            (core_done[c]),
                .stall_cycles    (core_stall_cycles[c])
            );
        end
    endgenerate

    // ── A read arbiter ───────────────────────────────────────────────────
    rr_read_arbiter #(
        .DATA_WIDTH   (DATA_WIDTH),
        .ADDR_WIDTH   (ADDR_WIDTH),
        .NUM_CORES    (NUM_CORES),
        .BRAM_LATENCY (BRAM_READ_LATENCY)
    ) u_a_arbiter (
        .clk          (clk),
        .rst          (rst),
        .req_valid    (a_req_valid),
        .req_addr     (a_req_addr),
        .req_ready    (a_req_ready),
        .resp_valid   (a_resp_valid),
        .resp_data    (a_resp_data),
        .bram_addr    (bram_a_addr),
        .bram_rd_en   (bram_a_rd_en),
        .bram_rd_data (bram_a_rd_data),
        .grant_count  (a_grant_count),
        .stall_cycles (a_stall_cycles)
    );

    // ── B read arbiter ───────────────────────────────────────────────────
    rr_read_arbiter #(
        .DATA_WIDTH   (DATA_WIDTH),
        .ADDR_WIDTH   (ADDR_WIDTH),
        .NUM_CORES    (NUM_CORES),
        .BRAM_LATENCY (BRAM_READ_LATENCY)
    ) u_b_arbiter (
        .clk          (clk),
        .rst          (rst),
        .req_valid    (b_req_valid),
        .req_addr     (b_req_addr),
        .req_ready    (b_req_ready),
        .resp_valid   (b_resp_valid),
        .resp_data    (b_resp_data),
        .bram_addr    (bram_b_addr),
        .bram_rd_en   (bram_b_rd_en),
        .bram_rd_data (bram_b_rd_data),
        .grant_count  (b_grant_count),
        .stall_cycles (b_stall_cycles)
    );

    // ── C write arbiter ──────────────────────────────────────────────────
    rr_write_arbiter #(
        .DATA_WIDTH (DATA_WIDTH),
        .ADDR_WIDTH (ADDR_WIDTH),
        .NUM_CORES  (NUM_CORES)
    ) u_c_arbiter (
        .clk          (clk),
        .rst          (rst),
        .req_valid    (c_req_valid),
        .req_addr     (c_req_addr),
        .req_data     (c_req_data),
        .req_ready    (c_req_ready),
        .bram_addr    (bram_c_addr),
        .bram_wr_data (bram_c_wr_data),
        .bram_wr_en   (bram_c_wr_en),
        .grant_count  (c_grant_count),
        .stall_cycles (c_stall_cycles)
    );

endmodule
