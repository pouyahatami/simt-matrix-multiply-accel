// =============================================================================
// File:    core.sv
//
// Module Description:
//   One compute core. Receives a block from the dispatcher via valid/ready
//   handshake + start pulse, runs the kernel via the scheduler, reports done.
//
// Contains:
//   1x scheduler, THREADS_PER_CORE x thread, address MUXes, A/B resp latches.
// =============================================================================

`timescale 1ns/1ns

module core #(
    parameter DATA_WIDTH       = 16,
    parameter ADDR_WIDTH       = 16,
    parameter THREADS_PER_CORE = 2,
    parameter TSEL = (THREADS_PER_CORE == 1) ? 1 : $clog2(THREADS_PER_CORE)
)(
    input  logic                    clk,
    input  logic                    rst,

    // Dispatcher handshake
    input  logic                    valid,
    output logic                    ready,
    input  logic                    start,
    input  logic [15:0]             thread_id_start,
    input  logic [7:0]              thread_count,

    // Kernel parameters (broadcast from gpu_top)
    input  logic [7:0]              N,
    input  logic [ADDR_WIDTH-1:0]   base_addr_A,
    input  logic [ADDR_WIDTH-1:0]   base_addr_B,
    input  logic [ADDR_WIDTH-1:0]   base_addr_C,

    // ── Memory-controller handshake: A read channel ─────────────────────
    output logic                    a_req_valid,
    output logic [ADDR_WIDTH-1:0]   a_req_addr,
    input  logic                    a_req_ready,
    input  logic                    a_resp_valid,
    input  logic [DATA_WIDTH-1:0]   a_resp_data,

    // ── Memory-controller handshake: B read channel ─────────────────────
    output logic                    b_req_valid,
    output logic [ADDR_WIDTH-1:0]   b_req_addr,
    input  logic                    b_req_ready,
    input  logic                    b_resp_valid,
    input  logic [DATA_WIDTH-1:0]   b_resp_data,

    // ── Memory-controller handshake: C write channel ────────────────────
    output logic                    c_req_valid,
    output logic [ADDR_WIDTH-1:0]   c_req_addr,
    output logic [DATA_WIDTH-1:0]   c_req_data,
    input  logic                    c_req_ready,

    //  Status back to dispatcher
    output logic                    done,

    // Debug — cycles this core spent stalled waiting on memory
    output logic [31:0]             stall_cycles
);

    // The core is "ready" when not currently running a block.
    logic busy;
    always_ff @(posedge clk) begin
        if (rst)          busy <= 1'b0;
        else if (start)   busy <= 1'b1;   // dispatcher kicked us off
        else if (done)    busy <= 1'b0;   // kernel finished
    end
    assign ready = !busy; //valid ready handshake

    // The dispatcher's `valid` is observed but not directly used here —
    // the actual "go" signal is `start` which the dispatcher pulses
    // exactly once when the handshake completes.
    /* verilator lint_off UNUSED */
    logic unused_valid;
    assign unused_valid = valid;
    /* verilator lint_on UNUSED */


    // Wires from scheduler
    logic [TSEL-1:0]                 t_select;
    logic [THREADS_PER_CORE-1:0]     data_valid;
    logic [THREADS_PER_CORE-1:0]     fma_en;
    logic [7:0]                      k;
    logic                            kernel_init;   // one-cycle pulse, broadcast to all threads

    scheduler #(
        .THREADS_PER_CORE (THREADS_PER_CORE)
    ) sched_inst (
        .clk          (clk),
        .rst          (rst),
        .start        (start),
        .N            (N),
        .thread_count (thread_count),
        .t_select     (t_select),
        .data_valid   (data_valid),
        .fma_en       (fma_en),
        .k            (k),
        .kernel_init  (kernel_init),

        .a_req_valid  (a_req_valid),
        .a_req_ready  (a_req_ready),
        .a_resp_valid (a_resp_valid),

        .b_req_valid  (b_req_valid),
        .b_req_ready  (b_req_ready),
        .b_resp_valid (b_resp_valid),

        .c_req_valid  (c_req_valid),
        .c_req_ready  (c_req_ready),

        .state        (/* unused */),
        .stall_cycles (stall_cycles),
        .done         (done)
    );

    // ── A/B response latches ────────────────────────────────────────────
    // The shared bus (a_resp_data/b_resp_data) only holds *this* core's
    // value during the single cycle resp_valid is high for it — another
    // core may be granted the very next cycle. Threads need a stable value
    // for the whole time between requests, so latch it here.
    logic [DATA_WIDTH-1:0] a_latched, b_latched;
    always_ff @(posedge clk) begin
        if (rst) begin
            a_latched <= '0;
            b_latched <= '0;
        end else begin
            if (a_resp_valid) a_latched <= a_resp_data;
            if (b_resp_valid) b_latched <= b_resp_data;
        end
    end

    // Per-thread output arrays (filled by thread instances)
    logic [ADDR_WIDTH-1:0]  thread_addr_A [THREADS_PER_CORE];
    logic [ADDR_WIDTH-1:0]  thread_addr_B [THREADS_PER_CORE];
    logic [ADDR_WIDTH-1:0]  thread_addr_C [THREADS_PER_CORE];
    logic [DATA_WIDTH-1:0]  thread_result [THREADS_PER_CORE];

    // ─────────────────────────────────────────────
    // Threads (generate loop)
    //   - Each thread gets a unique thread_id = thread_id_start + i
    //   - en = (i < thread_count) — disables threads beyond the block size
    //   - All threads share the latched A/B data buses
    // ─────────────────────────────────────────────
    genvar i;
    generate
        for (i = 0; i < THREADS_PER_CORE; i = i + 1) begin : g_threads
            thread #(
                .DATA_WIDTH (DATA_WIDTH),
                .ADDR_WIDTH (ADDR_WIDTH)
            ) th (
                .clk         (clk),
                .rst         (rst),
                .kernel_init (kernel_init),
                .en          (i < thread_count),
                .N           (N),
                .k           (k),
                .thread_id   (thread_id_start + 16'(i)),
                .base_addr_A (base_addr_A),
                .base_addr_B (base_addr_B),
                .base_addr_C (base_addr_C),
                .data_valid  (data_valid[i]),
                .a_val       (a_latched),
                .b_val       (b_latched),
                .data_ready  (),                  // unused
                .addr_A      (thread_addr_A[i]),
                .addr_B      (thread_addr_B[i]),
                .addr_C      (thread_addr_C[i]),
                .result      (thread_result[i])
            );
        end
    endgenerate

    // Address MUXes — pick t_select's thread address/data for each channel
    assign a_req_addr = thread_addr_A[t_select];
    assign b_req_addr = thread_addr_B[t_select];
    assign c_req_addr = thread_addr_C[t_select];
    assign c_req_data = thread_result[t_select];

endmodule
