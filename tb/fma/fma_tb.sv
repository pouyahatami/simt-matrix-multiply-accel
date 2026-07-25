module fma_tb;

    logic clk, rst;
    logic [15:0] a, b, c;
    logic valid_in;
    logic [15:0] result;    
    logic valid_out;

    int errors = 0;
    logic [15:0] expected;

    fma #(
        .DATA_WIDTH(16)
    ) dut (
        .clk       (clk),
        .rst       (rst),
        .a         (a),
        .b         (b),
        .c         (c),
        .valid_in  (valid_in),
        .result    (result),
        .valid_out (valid_out)
    );

    initial begin 
        clk = 0;
        forever begin 
            #5 clk = ~clk; // 100 MHz   
        end
    end 

    // Golden reference to compare results against
    function automatic logic [15:0] compute_golden(
        input logic [15:0] test_a,
        input logic [15:0] test_b,
        input logic [15:0] test_c
    );
        logic [31:0] product;
        begin
            product = test_a * test_b;
            compute_golden = product[15:0] + test_c;
        end
    endfunction

    // Test task: run one FMA operation with given inputs
    task automatic run_test(
        input logic [15:0] test_a,
        input logic [15:0] test_b,
        input logic [15:0] test_c
    );

        expected = compute_golden(test_a, test_b, test_c);

        $display("--- TEST: a=%0d, b=%0d, c=%0d, expected=%0d ---",
                 test_a, test_b, test_c, expected);

        // Drive inputs
        @(posedge clk);
        a        = test_a;
        b        = test_b;
        c        = test_c;
        valid_in = 1;

        @(posedge clk);
        valid_in = 0;

        // valid_out <= valid_in: high one cycle after valid_in was asserted
        if (valid_out !== 1'b1) begin
            $error("valid_out wrong: expected 1, got %0b", valid_out);
            errors++;
        end

        if (result !== expected) begin
            $error("result wrong: expected %0d, got %0d", expected, result);
            errors++;
        end else begin
            $display("    result = %0d  PASS", result);
        end

        @(posedge clk);
    endtask

    initial begin
        // Initialize inputs
        rst = 1;
        a = 0;
        b = 0;
        c = 0;
        valid_in = 0;

        // hold reset for two clock cycles
        repeat (2) @(posedge clk);

        rst = 0;

        // Run a few test cases
        run_test(16'd2,  16'd3,  16'd4);   // expected 10
        run_test(16'd5,  16'd6,  16'd7);   // expected 37
        run_test(16'd1,  16'd1,  16'd1);   // expected 2
        run_test(16'd10, 16'd10, 16'd5);   // expected 105
        run_test(16'd0,  16'd9,  16'd3);   // expected 3
        run_test(16'd15, 16'd2,  16'd1);   // expected 31

        // Final report
        if (errors == 0) begin
            $display("\n=== PASS ===");
        end else begin
            $display("\n=== FAIL: %0d errors ===", errors);
        end

        $finish;
    end

endmodule