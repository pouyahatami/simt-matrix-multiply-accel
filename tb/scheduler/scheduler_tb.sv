`timescale 1ns/1ps

// =============================================================================
// scheduler_tb.sv — unit test for v2 scheduler (stall-aware req/ready memory)
//
// Memory BFM models one read/write port each:
//   a/b_req_valid + req_ready  → grant (combinational when channel free)
//   a/b_resp_valid             → pulses READ_LATENCY cycles after grant
//   c_req_valid + c_req_ready  → write grant (same cycle)
//
// Tests:
//   1. Single block           N=3, thread_count=2
//   2. Multi-block re-entry   second start from DONE, no reset
//   3. Partial block          thread_count=1
//   4. Edge N=1               one FMA, one write
//   5. Slow memory            READ_LATENCY=2, checks stall_cycles > 0
//   6. Split A/B latency      A slower than B, still completes
// =============================================================================
module scheduler_tb;

    localparam THREADS_PER_CORE = 2;
    localparam TSEL             = (THREADS_PER_CORE == 1) ? 1 : $clog2(THREADS_PER_CORE);

    localparam [3:0] ST_IDLE      = 4'h0;
    localparam [3:0] ST_INIT      = 4'h1;
    localparam [3:0] ST_WAIT_AB   = 4'h2;
    localparam [3:0] ST_WRITE_REQ = 4'h6;
    localparam [3:0] ST_DONE      = 4'h8;

    logic clk, rst, start;
    logic [7:0] N, thread_count;

    logic [TSEL-1:0]             t_select;
    logic [THREADS_PER_CORE-1:0] data_valid, fma_en;
    logic [7:0]                  k;
    logic                        kernel_init;

    logic a_req_valid, a_req_ready, a_resp_valid;
    logic b_req_valid, b_req_ready, b_resp_valid;
    logic c_req_valid, c_req_ready;

    logic [3:0]  fsm_state;
    logic [31:0] stall_cycles;
    logic        done;

    // Memory BFM configuration (changed per test)
    int read_latency_a = 1;
    int read_latency_b = 1;
    bit c_stall_writes = 0;   // when set, hold c_req_ready low for 2 cycles

    int fma_count;
    int write_count;
    int kernel_init_count;
    int expected_t;
    int expected_k;
    int errors;
    int test_num;

    // ── Clock ───────────────────────────────────────────────────────────
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // ── DUT ─────────────────────────────────────────────────────────────
    scheduler #(
        .THREADS_PER_CORE (THREADS_PER_CORE)
    ) dut (
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
        .state        (fsm_state),
        .stall_cycles (stall_cycles),
        .done         (done)
    );

    // ── Read/write memory BFM ───────────────────────────────────────────
    logic        a_pending, b_pending;
    logic [7:0]  a_countdown, b_countdown;
    logic [1:0]  c_stall_count;

    assign a_req_ready = !a_pending;
    assign b_req_ready = !b_pending;
    assign c_req_ready = c_req_valid && (!c_stall_writes || c_stall_count >= 2);

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            a_pending    <= 1'b0;
            b_pending    <= 1'b0;
            a_countdown  <= 8'd0;
            b_countdown  <= 8'd0;
            a_resp_valid <= 1'b0;
            b_resp_valid <= 1'b0;
            c_stall_count <= 2'd0;
        end else begin
            a_resp_valid <= 1'b0;
            b_resp_valid <= 1'b0;

            if (a_req_valid && a_req_ready) begin
                a_pending   <= 1'b1;
                a_countdown <= (read_latency_a > 0) ? read_latency_a[7:0] - 8'd1 : 8'd0;
            end else if (a_pending) begin
                if (a_countdown > 8'd0)
                    a_countdown <= a_countdown - 8'd1;
                else begin
                    a_resp_valid <= 1'b1;
                    a_pending    <= 1'b0;
                end
            end

            if (b_req_valid && b_req_ready) begin
                b_pending   <= 1'b1;
                b_countdown <= (read_latency_b > 0) ? read_latency_b[7:0] - 8'd1 : 8'd0;
            end else if (b_pending) begin
                if (b_countdown > 8'd0)
                    b_countdown <= b_countdown - 8'd1;
                else begin
                    b_resp_valid <= 1'b1;
                    b_pending    <= 1'b0;
                end
            end

            if (c_stall_writes) begin
                if (c_req_valid && c_req_ready)
                    c_stall_count <= 2'd0;
                else if (c_req_valid)
                    c_stall_count <= c_stall_count + 2'd1;
                else
                    c_stall_count <= 2'd0;
            end else
                c_stall_count <= 2'd0;
        end
    end

    // ── FMA / write sequencing monitor ──────────────────────────────────
    always_ff @(posedge clk) begin
        if (!rst) begin
            if (kernel_init)
                kernel_init_count++;

            if (fma_en != '0) begin
                if (fma_en !== data_valid) begin
                    $error("Test %0d: fma_en/data_valid mismatch fma_en=%b data_valid=%b",
                           test_num, fma_en, data_valid);
                    errors++;
                end

                if (t_select != expected_t[TSEL-1:0]) begin
                    $error("Test %0d: expected thread %0d, got %0d",
                           test_num, expected_t, t_select);
                    errors++;
                end

                if (k != expected_k[7:0]) begin
                    $error("Test %0d: expected k=%0d, got %0d", test_num, expected_k, k);
                    errors++;
                end

                if (!fma_en[t_select] || !data_valid[t_select]) begin
                    $error("Test %0d: selected thread missing fma_en/data_valid", test_num);
                    errors++;
                end

                fma_count++;

                if (expected_t == int'(thread_count) - 1) begin
                    expected_t = 0;
                    expected_k++;
                end else begin
                    expected_t++;
                end
            end

            if (c_req_valid && c_req_ready)
                write_count++;
        end
    end

    task automatic reset_counters;
        fma_count         = 0;
        write_count       = 0;
        kernel_init_count = 0;
        expected_t        = 0;
        expected_k        = 0;
    endtask

    task automatic pulse_start;
        @(posedge clk);
        start = 1'b1;
        @(posedge clk);
        start = 1'b0;
    endtask

    task automatic wait_done;
        int timeout;
        begin
            timeout = 0;
            while (!done && timeout < 5000) begin
                @(posedge clk);
                timeout++;
            end
            if (!done) begin
                $error("Test %0d: timeout waiting for done (state=%0d)", test_num, fsm_state);
                errors++;
            end
        end
    endtask

    task automatic check_block_counts(
        input string label,
        input int    test_N,
        input int    test_tc,
        input int    expect_kernel_init
    );
        begin
            if (fma_count != test_N * test_tc) begin
                $error("%s: FMA count expected %0d, got %0d",
                       label, test_N * test_tc, fma_count);
                errors++;
            end else begin
                $display("PASS: %s — %0d FMA ops", label, fma_count);
            end

            if (write_count != test_tc) begin
                $error("%s: write count expected %0d, got %0d", label, test_tc, write_count);
                errors++;
            end else begin
                $display("PASS: %s — %0d C writes", label, write_count);
            end

            if (kernel_init_count != expect_kernel_init) begin
                $error("%s: kernel_init expected %0d, got %0d",
                       label, expect_kernel_init, kernel_init_count);
                errors++;
            end else begin
                $display("PASS: %s — kernel_init=%0d", label, kernel_init_count);
            end
        end
    endtask

    task automatic setup_bfm(
        input int lat_a,
        input int lat_b,
        input bit stall_c
    );
        begin
            read_latency_a = lat_a;
            read_latency_b = lat_b;
            c_stall_writes = stall_c;
        end
    endtask

    task automatic run_kernel(
        input string label,
        input int    test_N,
        input int    test_tc,
        input int    expect_kernel_init,
        input int    lat_a,
        input int    lat_b,
        input bit    stall_c
    );
        begin
            test_num++;
            $display("\nTEST %0d: %s (N=%0d, thread_count=%0d)", test_num, label, test_N, test_tc);

            setup_bfm(lat_a, lat_b, stall_c);
            N            = test_N[7:0];
            thread_count = test_tc[7:0];
            reset_counters;
            pulse_start;
            wait_done;
            @(posedge clk);
            check_block_counts(label, test_N, test_tc, expect_kernel_init);
        end
    endtask

    initial begin
        start        = 0;
        N            = 8'd3;
        thread_count = 8'd2;
        errors       = 0;
        test_num     = 0;

        setup_bfm(1, 1, 0);

        rst = 1'b1;
        repeat (3) @(posedge clk);
        rst = 1'b0;
        @(posedge clk);

        // 1 — normal kernel
        run_kernel("single block", 3, 2, 1, 1, 1, 0);

        // 2 — second kernel from DONE without reset
        run_kernel("multi-block re-entry", 3, 2, 1, 1, 1, 0);

        // 3 — only one hardware thread active
        run_kernel("partial block", 3, 1, 1, 1, 1, 0);

        // 4 — smallest matrix
        run_kernel("N=1 edge", 1, 1, 1, 1, 1, 0);

        // 5 — slow reads → scheduler should stall but still finish
        run_kernel("slow memory (lat=2)", 2, 2, 1, 2, 2, 0);
        if (stall_cycles == 0) begin
            $error("slow memory: expected stall_cycles > 0, got %0d", stall_cycles);
            errors++;
        end else begin
            $display("PASS: slow memory — stall_cycles=%0d", stall_cycles);
        end

        // 6 — A and B return on different schedules
        run_kernel("split A/B latency", 2, 2, 1, 3, 1, 0);

        // 7 — write path stalls
        test_num++;
        $display("\nTEST %0d: stalled C writes", test_num);
        setup_bfm(1, 1, 1);
        N            = 8'd2;
        thread_count = 8'd2;
        reset_counters;
        pulse_start;
        wait_done;
        @(posedge clk);
        check_block_counts("stalled C writes", 2, 2, 1);

        $display("\n══════════════════════════════════════════");
        if (errors == 0)
            $display(" ALL %0d TESTS PASSED", test_num);
        else
            $display(" FAIL: %0d errors across %0d tests", errors, test_num);
        $display("══════════════════════════════════════════");

        $finish;
    end

    initial begin
        #500000;
        $fatal(1, "TIMEOUT");
    end

endmodule
