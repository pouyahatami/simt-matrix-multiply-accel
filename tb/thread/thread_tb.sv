`timescale 1ns/1ps

module thread_tb;

    // DUT signals
    logic         clk, rst, en;
    logic         kernel_init;
    logic [7:0]   N, k;
    logic [15:0]  thread_id;
    logic [15:0]  base_addr_A, base_addr_B, base_addr_C;
    logic         data_valid;
    logic [15:0]  a_val, b_val;
    logic         data_ready;
    logic [15:0]  addr_A, addr_B, addr_C;
    logic [15:0]  result;

    // Memory model (simulated BRAM for A and B) ────────
    logic [15:0]  mem_A [0:255];
    logic [15:0]  mem_B [0:255];

    int           errors = 0;
    int           test_count = 0;
    logic [15:0]  expected;

    thread #(
        .DATA_WIDTH (16),
        .ADDR_WIDTH (16)
    ) dut (
        .clk         (clk),
        .rst         (rst),
        .en          (en),
        .kernel_init (kernel_init),
        .N           (N),
        .k           (k),
        .thread_id   (thread_id),
        .base_addr_A (base_addr_A),
        .base_addr_B (base_addr_B),
        .base_addr_C (base_addr_C),
        .data_valid  (data_valid),
        .a_val       (a_val),
        .b_val       (b_val),
        .data_ready  (data_ready),
        .addr_A      (addr_A),
        .addr_B      (addr_B),
        .addr_C      (addr_C),
        .result      (result)
    );



    // ─Memory responds combinationally to whatever address
    //    the thread asks for. This is the key trick — the
    //    thread's address-gen logic gets exercised because
    //    a_val/b_val depend on the addresses it produces.
    always_comb begin
        a_val = mem_A[addr_A[7:0]];
        b_val = mem_B[addr_B[7:0]];
    end

    // Match tb/core/matrixA.mif and matrixB.mif (same data as FPGA target).
    initial begin
        for (int i = 0; i < 16; i++)
            mem_A[i] = 16'(i + 1);
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
    end

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    function automatic logic [15:0] compute_golden(
        input int row, col, NN
    );
        logic [15:0] acc = 0;
        for (int kk = 0; kk < NN; kk++)
            acc += mem_A[row * NN + kk] * mem_B[kk * NN + col];
        return acc;
    endfunction

    // Pulse kernel_init once — same 1-cycle pulse the scheduler sends at INIT.
    task automatic pulse_kernel_init;
        kernel_init = 1'b1;
        @(posedge clk);
        kernel_init = 1'b0;
        @(posedge clk);
    endtask

    // Shared k-loop: drive k=0..N-1 and pulse data_valid each iteration.
    task automatic run_k_loop(
        input int row,
        input int col,
        input int test_N
    );
        for (int kk = 0; kk < test_N; kk++) begin
            k = kk[7:0];
            @(posedge clk);

            if (addr_A !== row * test_N + kk) begin
                $error("addr_A wrong at k=%0d: expected %0d, got %0d",
                       kk, row * test_N + kk, addr_A);
                errors++;
            end
            if (addr_B !== kk * test_N + col) begin
                $error("addr_B wrong at k=%0d: expected %0d, got %0d",
                       kk, kk * test_N + col, addr_B);
                errors++;
            end

            data_valid = 1'b1;
            @(posedge clk);
            data_valid = 1'b0;
            @(posedge clk);
        end
    endtask

    task automatic check_result(
        input int row,
        input int col,
        input int test_N
    );
        repeat (5) @(posedge clk);

        if (result !== expected) begin
            $error("  result wrong: expected %0d, got %0d", expected, result);
            errors++;
        end

        if (addr_C !== row * test_N + col) begin
            $error("addr_C wrong: expected %0d, got %0d",
                   row * test_N + col, addr_C);
            errors++;
        end
    endtask

    task automatic run_test(
        input int test_thread_id,
        input int test_N
    );
        int row, col;

        test_count++;
        row = test_thread_id / test_N;
        col = test_thread_id % test_N;
        expected = compute_golden(row, col, test_N);

        $display("Test %0d: thread_id=%0d N=%0d (row,col)=(%0d,%0d) expected=%0d",
                 test_count, test_thread_id, test_N, row, col, expected);

        rst         = 1'b1;
        en          = 1'b0;
        kernel_init = 1'b0;
        data_valid  = 1'b0;
        N           = test_N[7:0];
        thread_id   = test_thread_id[15:0];
        base_addr_A = 16'h0000;
        base_addr_B = 16'h0000;
        base_addr_C = 16'h0000;
        k           = 8'd0;
        repeat (3) @(posedge clk);

        rst = 1'b0;
        en  = 1'b1;
        pulse_kernel_init;
        run_k_loop(row, col, test_N);
        check_result(row, col, test_N);

        en = 1'b0;
    endtask

    // Two kernels back-to-back without reset — tests kernel_init clears accumulator.
    task automatic run_test_back_to_back;
        int row, col;

        test_count++;
        $display("Test %0d: back-to-back kernels (no reset between jobs)", test_count);

        rst         = 1'b1;
        en          = 1'b0;
        kernel_init = 1'b0;
        data_valid  = 1'b0;
        N           = 8'd4;
        base_addr_A = 16'h0000;
        base_addr_B = 16'h0000;
        base_addr_C = 16'h0000;
        repeat (3) @(posedge clk);

        rst = 1'b0;
        en  = 1'b1;

        // Job 1: C[0][0]
        thread_id = 16'd0;
        row = 0; col = 0;
        expected = compute_golden(row, col, 4);
        pulse_kernel_init;
        run_k_loop(row, col, 4);
        check_result(row, col, 4);

        // Job 2: C[0][1] — no rst, only kernel_init
        thread_id = 16'd1;
        row = 0; col = 1;
        expected = compute_golden(row, col, 4);
        pulse_kernel_init;
        run_k_loop(row, col, 4);
        check_result(row, col, 4);

        en = 1'b0;
    endtask

    initial begin
        #20;

        run_test( 0, 4);
        run_test( 5, 4);
        run_test(15, 4);

        run_test( 0, 2);
        run_test( 3, 2);

        run_test( 0, 1);
        run_test( 3, 4);

        run_test_back_to_back;

        $display("\n══════════════════════════════════════════");
        if (errors == 0) $display(" ALL %0d TESTS PASSED", test_count);
        else             $display(" FAIL: %0d errors across %0d tests", errors, test_count);
        $display("══════════════════════════════════════════");
        $finish;
    end

endmodule
