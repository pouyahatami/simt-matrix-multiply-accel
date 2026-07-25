`timescale 1ns/1ps

// =============================================================================
// Core_tb.sv — unit test for v2 core (scheduler + threads + req/ready memory)
//
// Pure SystemVerilog memory model (no Quartus MATRIX_* IP). Data matches
// tb/core/matrixA.mif and matrixB.mif. Replaces v1 ports (addr_A_out, we_C)
// and SVA checks with procedural tests compatible with ModelSim ASE.
//
// Tests:
//   1–4. Full 4×4 matmul — four blocks of four threads (rows 0..3)
//   5.   Partial block    — thread_count=2
//   6.   Back-to-back     — two blocks without reset
//   7.   Slow memory      — read latency=2, one block
// =============================================================================
module Core_tb;

    localparam DATA_WIDTH       = 16;
    localparam ADDR_WIDTH       = 16;
    localparam THREADS_PER_CORE = 4;

    logic clk, rst;
    logic valid, ready, start;
    logic [15:0] thread_id_start;
    logic [7:0]  thread_count, N;
    logic [ADDR_WIDTH-1:0] base_addr_A, base_addr_B, base_addr_C;

    logic a_req_valid, a_req_ready, a_resp_valid;
    logic [ADDR_WIDTH-1:0]   a_req_addr;
    logic [DATA_WIDTH-1:0]   a_resp_data;

    logic b_req_valid, b_req_ready, b_resp_valid;
    logic [ADDR_WIDTH-1:0]   b_req_addr;
    logic [DATA_WIDTH-1:0]   b_resp_data;

    logic c_req_valid, c_req_ready;
    logic [ADDR_WIDTH-1:0]   c_req_addr;
    logic [DATA_WIDTH-1:0]   c_req_data;

    logic        done;
    logic [31:0] stall_cycles;

    logic [DATA_WIDTH-1:0] mem_A [0:255];
    logic [DATA_WIDTH-1:0] mem_B [0:255];
    logic [DATA_WIDTH-1:0] mem_C [0:255];

    int read_latency_a = 1;
    int read_latency_b = 1;
    int errors         = 0;
    int test_count     = 0;
    int block_writes   = 0;

    // ── Clock ───────────────────────────────────────────────────────────
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // ── DUT ─────────────────────────────────────────────────────────────
    core #(
        .DATA_WIDTH       (DATA_WIDTH),
        .ADDR_WIDTH       (ADDR_WIDTH),
        .THREADS_PER_CORE (THREADS_PER_CORE)
    ) dut (
        .clk             (clk),
        .rst             (rst),
        .valid           (valid),
        .ready           (ready),
        .start           (start),
        .thread_id_start (thread_id_start),
        .thread_count    (thread_count),
        .N               (N),
        .base_addr_A     (base_addr_A),
        .base_addr_B     (base_addr_B),
        .base_addr_C     (base_addr_C),
        .a_req_valid     (a_req_valid),
        .a_req_addr      (a_req_addr),
        .a_req_ready     (a_req_ready),
        .a_resp_valid    (a_resp_valid),
        .a_resp_data     (a_resp_data),
        .b_req_valid     (b_req_valid),
        .b_req_addr      (b_req_addr),
        .b_req_ready     (b_req_ready),
        .b_resp_valid    (b_resp_valid),
        .b_resp_data     (b_resp_data),
        .c_req_valid     (c_req_valid),
        .c_req_addr      (c_req_addr),
        .c_req_data      (c_req_data),
        .c_req_ready     (c_req_ready),
        .done            (done),
        .stall_cycles    (stall_cycles)
    );

    // ── Load matrixA.mif / matrixB.mif golden data ────────────────────────
    initial begin
        for (int i = 0; i < 16; i++)
            mem_A[i] = DATA_WIDTH'(i + 1);
        for (int i = 16; i < 256; i++)
            mem_A[i] = 16'h0000;

        mem_B[ 0] = 16'h0001; mem_B[ 1] = 16'h0002;
        mem_B[ 2] = 16'h0000; mem_B[ 3] = 16'h0001;
        mem_B[ 4] = 16'h0000; mem_B[ 5] = 16'h0001;
        mem_B[ 6] = 16'h0002; mem_B[ 7] = 16'h0000;
        mem_B[ 8] = 16'h0001; mem_B[ 9] = 16'h0000;
        mem_B[10] = 16'h0001; mem_B[11] = 16'h0002;
        mem_B[12] = 16'h0002; mem_B[13] = 16'h0001;
        mem_B[14] = 16'h0000; mem_B[15] = 16'h0001;
        for (int i = 16; i < 256; i++)
            mem_B[i] = 16'h0000;

        for (int i = 0; i < 256; i++)
            mem_C[i] = 16'h0000;
    end

    function automatic logic [DATA_WIDTH-1:0] compute_golden(
        input int row, col, NN
    );
        logic [DATA_WIDTH-1:0] acc = 0;
        for (int kk = 0; kk < NN; kk++)
            acc += mem_A[row * NN + kk] * mem_B[kk * NN + col];
        return acc;
    endfunction

    // ── Memory BFM (A/B read + C write) ─────────────────────────────────
    logic                  a_pending, b_pending;
    logic [7:0]            a_countdown, b_countdown;
    logic [ADDR_WIDTH-1:0] a_pending_addr, b_pending_addr;

    assign a_req_ready = !a_pending;
    assign b_req_ready = !b_pending;
    assign c_req_ready = c_req_valid;

    assign a_resp_data = mem_A[a_pending_addr[7:0]];
    assign b_resp_data = mem_B[b_pending_addr[7:0]];

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            a_pending      <= 1'b0;
            b_pending      <= 1'b0;
            a_countdown    <= 8'd0;
            b_countdown    <= 8'd0;
            a_resp_valid   <= 1'b0;
            b_resp_valid   <= 1'b0;
            a_pending_addr <= '0;
            b_pending_addr <= '0;
        end else begin
            a_resp_valid <= 1'b0;
            b_resp_valid <= 1'b0;

            if (a_req_valid && a_req_ready) begin
                a_pending      <= 1'b1;
                a_pending_addr <= a_req_addr;
                a_countdown    <= (read_latency_a > 0) ? read_latency_a[7:0] - 8'd1 : 8'd0;
            end else if (a_pending) begin
                if (a_countdown > 8'd0)
                    a_countdown <= a_countdown - 8'd1;
                else begin
                    a_resp_valid <= 1'b1;
                    a_pending    <= 1'b0;
                end
            end

            if (b_req_valid && b_req_ready) begin
                b_pending      <= 1'b1;
                b_pending_addr <= b_req_addr;
                b_countdown    <= (read_latency_b > 0) ? read_latency_b[7:0] - 8'd1 : 8'd0;
            end else if (b_pending) begin
                if (b_countdown > 8'd0)
                    b_countdown <= b_countdown - 8'd1;
                else begin
                    b_resp_valid <= 1'b1;
                    b_pending    <= 1'b0;
                end
            end

            if (c_req_valid && c_req_ready)
                mem_C[c_req_addr[7:0]] <= c_req_data;
        end
    end

    // ── Check each C write against golden model ───────────────────────────
    always_ff @(posedge clk) begin
        int row, col;
        logic [DATA_WIDTH-1:0] expected;

        if (!rst && c_req_valid && c_req_ready) begin
            block_writes++;
            row = int'(c_req_addr) / int'(N);
            col = int'(c_req_addr) % int'(N);
            expected = compute_golden(row, col, int'(N));

            if (c_req_data !== expected) begin
                $error("Test %0d: C[%0d][%0d] expected %0d, got %0d",
                       test_count, row, col, expected, c_req_data);
                errors++;
            end else begin
                $display("  PASS: C[%0d][%0d] = %0d", row, col, c_req_data);
            end
        end
    end

    task automatic setup_memory(
        input int lat_a,
        input int lat_b
    );
        begin
            read_latency_a = lat_a;
            read_latency_b = lat_b;
        end
    endtask

    task automatic clear_matrix_c;
        begin
            for (int i = 0; i < 256; i++)
                mem_C[i] = 16'h0000;
        end
    endtask

    task automatic pulse_start_after_handshake;
        begin
            if (!ready) begin
                $error("Test %0d: core not ready before handshake", test_count);
                errors++;
            end

            valid = 1'b1;
            @(posedge clk);

            if (!(valid && ready)) begin
                $error("Test %0d: valid&ready handshake failed", test_count);
                errors++;
            end

            valid = 1'b0;
            start = 1'b1;
            @(posedge clk);
            start = 1'b0;
        end
    endtask

    task automatic wait_done;
        int timeout;
        begin
            timeout = 0;
            while (!done && timeout < 20000) begin
                @(posedge clk);
                timeout++;
            end
            if (!done) begin
                $error("Test %0d: timeout waiting for done", test_count);
                errors++;
            end
        end
    endtask

    task automatic run_block(
        input int  test_thread_id_start,
        input int  test_tc,
        input int  test_N,
        input bit  do_reset,
        input int  lat_a,
        input int  lat_b
    );
        begin
            test_count++;
            $display("\nTest %0d: thread_id_start=%0d thread_count=%0d N=%0d (reset=%0d)",
                     test_count, test_thread_id_start, test_tc, test_N, do_reset);

            setup_memory(lat_a, lat_b);
            block_writes    = 0;
            N               = test_N[7:0];
            thread_id_start = test_thread_id_start[15:0];
            thread_count    = test_tc[7:0];
            base_addr_A     = 16'h0000;
            base_addr_B     = 16'h0000;
            base_addr_C     = 16'h0000;
            valid           = 1'b0;
            start           = 1'b0;

            if (do_reset) begin
                rst = 1'b1;
                repeat (3) @(posedge clk);
                rst = 1'b0;
                @(posedge clk);
            end

            pulse_start_after_handshake;
            wait_done;
            @(posedge clk);

            $display("  writes=%0d (expected %0d), stall_cycles=%0d",
                     block_writes, test_tc, stall_cycles);

            if (block_writes != test_tc) begin
                $error("Test %0d: wrong write count", test_count);
                errors++;
            end
        end
    endtask

    task automatic run_back_to_back;
        begin
            test_count++;
            $display("\nTest %0d: back-to-back blocks (no reset)", test_count);

            setup_memory(1, 1);
            N            = 8'd4;
            thread_count = 8'd4;
            base_addr_A  = 16'h0000;
            base_addr_B  = 16'h0000;
            base_addr_C  = 16'h0000;
            clear_matrix_c;

            rst = 1'b1;
            repeat (3) @(posedge clk);
            rst = 1'b0;
            @(posedge clk);

            // Block 1 — row 0
            thread_id_start = 16'd0;
            pulse_start_after_handshake;
            wait_done;
            @(posedge clk);

            if (!ready) begin
                $error("Test %0d: core not ready after first block", test_count);
                errors++;
            end

            // Block 2 — row 1, no reset
            thread_id_start = 16'd4;
            pulse_start_after_handshake;
            wait_done;
            @(posedge clk);

            // Spot-check two cells written by each block
            if (mem_C[0] !== compute_golden(0, 0, 4)) begin
                $error("Test %0d: mem_C[0] wrong after back-to-back", test_count);
                errors++;
            end
            if (mem_C[4] !== compute_golden(1, 0, 4)) begin
                $error("Test %0d: mem_C[4] wrong after back-to-back", test_count);
                errors++;
            end else begin
                $display("  PASS: back-to-back C[0][0] and C[1][0] correct");
            end
        end
    endtask

    task automatic verify_full_matrix;
        int row, col;
        int local_errors;
        logic [DATA_WIDTH-1:0] expected;
        begin
            test_count++;
            local_errors = 0;
            $display("\nTest %0d: verify full 4×4 result matrix", test_count);

            for (row = 0; row < 4; row++) begin
                for (col = 0; col < 4; col++) begin
                    expected = compute_golden(row, col, 4);
                    if (mem_C[row * 4 + col] !== expected) begin
                        $error("  C[%0d][%0d]: expected %0d, mem has %0d",
                               row, col, expected, mem_C[row * 4 + col]);
                        local_errors++;
                    end
                end
            end

            if (local_errors != 0)
                errors += local_errors;
            else
                $display("  PASS: all 16 elements match golden model");
        end
    endtask

    initial begin
        valid = 0;
        start = 0;
        rst   = 1;

        #20;

        // Full 4×4 — one block per row (same coverage as original Core_tb)
        run_block( 0, 4, 4, 1, 1, 1);
        run_block( 4, 4, 4, 1, 1, 1);
        run_block( 8, 4, 4, 1, 1, 1);
        run_block(12, 4, 4, 1, 1, 1);

        // Partial block — only 2 threads active
        run_block(0, 2, 4, 1, 1, 1);

        // Slow memory — read latency 2
        run_block(0, 4, 4, 1, 2, 2);

        // Back-to-back dispatch without reset
        run_back_to_back;

        // Accumulate all four rows into mem_C and verify
        clear_matrix_c;
        setup_memory(1, 1);
        N            = 8'd4;
        thread_count = 8'd4;
        base_addr_A  = 16'h0000;
        base_addr_B  = 16'h0000;
        base_addr_C  = 16'h0000;
        rst = 1'b1;
        repeat (3) @(posedge clk);
        rst = 1'b0;
        @(posedge clk);

        run_block( 0, 4, 4, 0, 1, 1);
        run_block( 4, 4, 4, 0, 1, 1);
        run_block( 8, 4, 4, 0, 1, 1);
        run_block(12, 4, 4, 0, 1, 1);
        verify_full_matrix;

        $display("\n══════════════════════════════════════════");
        if (errors == 0)
            $display(" ALL %0d TESTS PASSED", test_count);
        else
            $display(" FAIL: %0d errors across %0d tests", errors, test_count);
        $display("══════════════════════════════════════════");

        $finish;
    end

    initial begin
        #2000000;
        $fatal(1, "TIMEOUT");
    end

endmodule
