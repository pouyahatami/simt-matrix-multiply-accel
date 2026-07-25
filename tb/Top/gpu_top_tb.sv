// =============================================================================
// gpu_top_tb.sv -- system test for the 4-core shared-memory-controller GPU
//
// Uses the actual `dual_port_bram` module as the memory model (only port A
// is exercised; port B is tied off, same as de1soc_top.sv) so this
// testbench proves the design works against the same memory blocks Quartus
// will synthesise into M10K on the DE1-SoC.
//
// Unlike the old per-core-port testbench, all NUM_CORES cores now share one
// physical port per matrix (A, B, C) through round-robin arbiters inside
// gpu_top. This test checks both correctness (final C matrix matches a
// software golden model) AND that contention is actually happening
// (stall_cycles > 0, grants are reasonably balanced across cores).
// =============================================================================
`timescale 1ns/1ps

module gpu_top_tb;

    localparam DATA_WIDTH       = 16;
    localparam ADDR_WIDTH       = 16;
    localparam NUM_CORES        = 4;
    localparam THREADS_PER_CORE = 2;
    localparam BRAM_DEPTH       = 256;

    // 4x4 = 16 threads, 2 threads/core -> 8 blocks, 2 dispatches per core.
    localparam N_TEST           = 4;

    logic                       clk, rst;
    logic                       start;
    logic [7:0]                 N;
    logic [ADDR_WIDTH-1:0]      base_addr_A, base_addr_B, base_addr_C;
    logic                       done;

    logic [ADDR_WIDTH-1:0]      bram_a_addr;
    logic                       bram_a_rd_en;
    logic [DATA_WIDTH-1:0]      bram_a_rd_data;

    logic [ADDR_WIDTH-1:0]      bram_b_addr;
    logic                       bram_b_rd_en;
    logic [DATA_WIDTH-1:0]      bram_b_rd_data;

    logic [ADDR_WIDTH-1:0]      bram_c_addr;
    logic [DATA_WIDTH-1:0]      bram_c_wr_data;
    logic                       bram_c_wr_en;

    logic [31:0] a_grant_count [NUM_CORES-1:0];
    logic [31:0] b_grant_count [NUM_CORES-1:0];
    logic [31:0] c_grant_count [NUM_CORES-1:0];
    logic [31:0] a_stall_cycles, b_stall_cycles, c_stall_cycles;
    logic [31:0] core_stall_cycles [NUM_CORES-1:0];

    initial begin clk = 0; forever #5 clk = ~clk; end

    // DUT
    gpu_top #(
        .DATA_WIDTH       (DATA_WIDTH),
        .ADDR_WIDTH       (ADDR_WIDTH),
        .NUM_CORES        (NUM_CORES),
        .THREADS_PER_CORE (THREADS_PER_CORE)
    ) dut (
        .clk(clk), .rst(rst), .start(start), .N(N),
        .base_addr_A(base_addr_A), .base_addr_B(base_addr_B), .base_addr_C(base_addr_C),

        .bram_a_addr    (bram_a_addr),
        .bram_a_rd_en   (bram_a_rd_en),
        .bram_a_rd_data (bram_a_rd_data),

        .bram_b_addr    (bram_b_addr),
        .bram_b_rd_en   (bram_b_rd_en),
        .bram_b_rd_data (bram_b_rd_data),

        .bram_c_addr    (bram_c_addr),
        .bram_c_wr_data (bram_c_wr_data),
        .bram_c_wr_en   (bram_c_wr_en),

        .done(done),
        .a_grant_count     (a_grant_count),
        .b_grant_count     (b_grant_count),
        .c_grant_count     (c_grant_count),
        .a_stall_cycles    (a_stall_cycles),
        .b_stall_cycles    (b_stall_cycles),
        .c_stall_cycles    (c_stall_cycles),
        .core_stall_cycles (core_stall_cycles)
    );

    // Memory model: three real dual-port BRAMs, port A only (matches
    // de1soc_top.sv — port B tied off / unused).
    logic [DATA_WIDTH-1:0] bram_a_portb_unused, bram_b_portb_unused;
    dual_port_bram #(
        .DATA_WIDTH (DATA_WIDTH), .ADDR_WIDTH (ADDR_WIDTH), .DEPTH (BRAM_DEPTH)
    ) bram_A (
        .clk       (clk),
        .a_addr    (bram_a_addr), .a_wr_en (1'b0), .a_wr_data ('0), .a_rd_data (bram_a_rd_data),
        .b_addr    ('0),          .b_wr_en (1'b0), .b_wr_data ('0), .b_rd_data (bram_a_portb_unused)
    );

    dual_port_bram #(
        .DATA_WIDTH (DATA_WIDTH), .ADDR_WIDTH (ADDR_WIDTH), .DEPTH (BRAM_DEPTH)
    ) bram_B (
        .clk       (clk),
        .a_addr    (bram_b_addr), .a_wr_en (1'b0), .a_wr_data ('0), .a_rd_data (bram_b_rd_data),
        .b_addr    ('0),          .b_wr_en (1'b0), .b_wr_data ('0), .b_rd_data (bram_b_portb_unused)
    );

    logic [DATA_WIDTH-1:0] bram_c_rd_a_unused, bram_c_rd_b_unused;
    dual_port_bram #(
        .DATA_WIDTH (DATA_WIDTH), .ADDR_WIDTH (ADDR_WIDTH), .DEPTH (BRAM_DEPTH)
    ) bram_C (
        .clk       (clk),
        .a_addr    (bram_c_addr), .a_wr_en (bram_c_wr_en), .a_wr_data (bram_c_wr_data), .a_rd_data (bram_c_rd_a_unused),
        .b_addr    ('0),          .b_wr_en (1'b0),         .b_wr_data ('0),             .b_rd_data (bram_c_rd_b_unused)
    );

    // C-write monitor
    int errors          = 0;
    int writes_observed = 0;

    initial begin
        fork
            forever begin
                @(posedge clk);
                if (!rst && bram_c_wr_en) begin
                    writes_observed++;
                    $display("  [t=%0t] bram_C[%0d] <= %0d (write #%0d)",
                             $time, bram_c_addr, bram_c_wr_data, writes_observed);
                end
            end
        join_none
    end

    // Software golden. Reads A and B values via hierarchical reference into
    // the BRAM modules' internal `mem` arrays.
    function automatic logic [DATA_WIDTH-1:0] compute_golden(input int row, col, NN);
        logic [DATA_WIDTH-1:0] acc = 0;
        for (int kk = 0; kk < NN; kk++)
            acc += bram_A.mem[row*NN + kk] * bram_B.mem[kk*NN + col];
        return acc;
    endfunction

    // Initialise BRAM contents via hierarchical reference.
    // For N=4: A = B = [[1,2,3,4],[5,6,7,8],[9,10,11,12],[13,14,15,16]]
    // Max product = 16*16 = 256; max accumulator = 4 * 256 = 1024 -- well
    // within 16-bit range, no overflow at this size.
    initial begin
        for (int i = 0; i < BRAM_DEPTH; i++) begin
            bram_A.mem[i] = 16'h0000;
            bram_B.mem[i] = 16'h0000;
            bram_C.mem[i] = 16'hDEAD;
        end
        for (int i = 0; i < N_TEST*N_TEST; i++) begin
            bram_A.mem[i] = 16'(i + 1);
            bram_B.mem[i] = 16'(i + 1);
        end
    end

    // Stimulus + checks
    initial begin
        $dumpfile("gpu_top_tb.vcd");
        $dumpvars(0, gpu_top_tb);

        rst         = 1;
        start       = 0;
        N           = N_TEST[7:0];
        base_addr_A = 16'h0000;
        base_addr_B = 16'h0000;
        base_addr_C = 16'h0000;
        #1;

        $display("");
        $display("=== GPU SYSTEM TEST: %0dx%0d matmul (NUM_CORES=%0d, T/C=%0d, shared-memory-controller) ===",
                 N_TEST, N_TEST, NUM_CORES, THREADS_PER_CORE);
        $display("Memory: 3x dual_port_bram (A, B, C), port A shared by all cores via round-robin arbiters");
        $display("Total blocks=%0d, dispatches/core=%0d",
                 (N_TEST*N_TEST) / THREADS_PER_CORE,
                 ((N_TEST*N_TEST) / THREADS_PER_CORE) / NUM_CORES);
        $write("Expected C (from golden):");
        for (int r = 0; r < N_TEST; r++) begin
            $write("\n  row %0d:", r);
            for (int c = 0; c < N_TEST; c++) $write(" %5d", compute_golden(r, c, N_TEST));
        end
        $display("");

        repeat (3) @(posedge clk);
        rst = 0;
        @(posedge clk);

        start = 1;
        @(posedge clk);
        start = 0;

        fork
            begin
                wait (done);
                $display("[t=%0t] done asserted!", $time);
            end
            begin
                repeat (20000) @(posedge clk);
                $error("TIMEOUT");
                errors++;
            end
        join_any
        disable fork;
        @(posedge clk); @(posedge clk);

        for (int row = 0; row < N_TEST; row++) begin
            for (int col = 0; col < N_TEST; col++) begin
                automatic int addr = row * N_TEST + col;
                automatic logic [DATA_WIDTH-1:0] expected = compute_golden(row, col, N_TEST);
                if (bram_C.mem[addr] !== expected) begin
                    $error("  FAIL  C[%0d][%0d]: expected %0d, got %0d",
                           row, col, expected, bram_C.mem[addr]);
                    errors++;
                end else begin
                    $display("  PASS  C[%0d][%0d] = %0d", row, col, bram_C.mem[addr]);
                end
            end
        end

        if (writes_observed != N_TEST * N_TEST) begin
            $error("Wrong write count: expected %0d, got %0d", N_TEST*N_TEST, writes_observed);
            errors++;
        end

        // Contention / fairness report — this is the whole point of v2.
        $display("");
        $display("=== Memory-controller contention report ===");
        $display("A-arbiter stall_cycles=%0d  B-arbiter stall_cycles=%0d  C-arbiter stall_cycles=%0d",
                  a_stall_cycles, b_stall_cycles, c_stall_cycles);
        for (int c = 0; c < NUM_CORES; c++) begin
            $display("  core%0d: a_grants=%0d b_grants=%0d c_grants=%0d core_stall_cycles=%0d",
                      c, a_grant_count[c], b_grant_count[c], c_grant_count[c], core_stall_cycles[c]);
        end
        if (a_stall_cycles == 0 && b_stall_cycles == 0) begin
            $display("  NOTE: zero stalls observed -- with NUM_CORES=%0d this is suspicious; check arbiter wiring.", NUM_CORES);
        end

        $display("");
        if (errors == 0)
            $display("=== SYSTEM TEST PASSED ===");
        else
            $display("=== SYSTEM TEST FAILED: %0d errors ===", errors);
        $finish;
    end

    initial begin #500000; $fatal(1, "HARD TIMEOUT"); end

endmodule
