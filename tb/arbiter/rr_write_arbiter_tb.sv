`timescale 1ns/1ps

// =============================================================================
// rr_write_arbiter_tb — unit test for v2 write arbiter (req_valid/ready, same-cycle commit)
// =============================================================================
module rr_write_arbiter_tb;

    localparam DATA_WIDTH = 16;
    localparam ADDR_WIDTH = 16;
    localparam NUM_CORES  = 2;

    logic clk, rst;

    logic [NUM_CORES-1:0]   req_valid;
    logic [ADDR_WIDTH-1:0]  req_addr   [NUM_CORES-1:0];
    logic [DATA_WIDTH-1:0]  req_data   [NUM_CORES-1:0];
    logic [NUM_CORES-1:0]   req_ready;

    logic [ADDR_WIDTH-1:0]  bram_addr;
    logic [DATA_WIDTH-1:0]  bram_wr_data;
    logic                   bram_wr_en;

    logic [31:0]            grant_count [NUM_CORES-1:0];
    logic [31:0]            stall_cycles;

    logic [DATA_WIDTH-1:0]  mem_storage [0:255];

    int errors = 0;
    int grants_per_core [NUM_CORES-1:0];

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    initial begin
        integer i;
        for (i = 0; i < 256; i = i + 1)
            mem_storage[i] = 0;
    end

    always @(posedge clk) begin
        if (bram_wr_en)
            mem_storage[bram_addr[7:0]] <= bram_wr_data;
    end

    rr_write_arbiter #(
        .DATA_WIDTH (DATA_WIDTH),
        .ADDR_WIDTH (ADDR_WIDTH),
        .NUM_CORES  (NUM_CORES)
    ) dut (
        .clk          (clk),
        .rst          (rst),
        .req_valid    (req_valid),
        .req_addr     (req_addr),
        .req_data     (req_data),
        .req_ready    (req_ready),
        .bram_addr    (bram_addr),
        .bram_wr_data (bram_wr_data),
        .bram_wr_en   (bram_wr_en),
        .grant_count  (grant_count),
        .stall_cycles (stall_cycles)
    );

    initial begin
        integer i;
        for (i = 0; i < NUM_CORES; i = i + 1) begin
            grants_per_core[i] = 0;
            req_valid[i]       = 0;
            req_addr[i]        = 0;
            req_data[i]        = 0;
        end
    end

    always @(posedge clk) begin
        integer i;
        int     n_req;

        if (!rst) begin
            if ($countones(req_ready) > 1) begin
                $error("VIOLATION: multiple write grants");
                errors = errors + 1;
            end

            if ((req_ready & ~req_valid) != 0) begin
                $error("VIOLATION: write grant without request");
                errors = errors + 1;
            end

            n_req = $countones(req_valid);
            if (n_req == 1 && req_ready == 0) begin
                $error("VIOLATION: solo write request but no grant");
                errors = errors + 1;
            end

            for (i = 0; i < NUM_CORES; i = i + 1)
                if (req_ready[i])
                    grants_per_core[i] = grants_per_core[i] + 1;
        end
    end

    task do_reset;
        integer i;
        begin
            rst = 1;
            for (i = 0; i < NUM_CORES; i = i + 1)
                req_valid[i] = 0;
            repeat (3) @(posedge clk);
            rst = 0;
            @(posedge clk);
        end
    endtask

    task clear_requests;
        integer i;
        begin
            for (i = 0; i < NUM_CORES; i = i + 1)
                req_valid[i] = 0;
        end
    endtask

    task do_write_and_check;
        input integer          core_idx;
        input [ADDR_WIDTH-1:0] addr;
        input [DATA_WIDTH-1:0] data;
        begin
            req_addr[core_idx]  = addr;
            req_data[core_idx]  = data;
            req_valid[core_idx] = 1;

            @(posedge clk);

            if (!req_ready[core_idx]) begin
                $error("Core %0d should have been granted write addr=0x%h", core_idx, addr);
                errors = errors + 1;
            end

            req_valid[core_idx] = 0;
            @(posedge clk);

            if (mem_storage[addr[7:0]] !== data) begin
                $error("Write failed: [0x%h] expected 0x%h, got 0x%h",
                       addr, data, mem_storage[addr[7:0]]);
                errors = errors + 1;
            end else begin
                $display("PASS: Core %0d wrote [0x%h] = 0x%h", core_idx, addr, data);
            end
        end
    endtask

    task test_solo_write;
        begin
            $display("\nTEST: solo writes");
            do_reset;

            do_write_and_check(0, 16'h0030, 16'hCAFE);
            clear_requests;
            @(posedge clk);

            do_write_and_check(1, 16'h0040, 16'hBEEF);
            clear_requests;
            @(posedge clk);
        end
    endtask

    task test_fairness;
        integer rg0_before;
        integer rg1_before;
        begin
            $display("\nTEST: round-robin fairness");
            do_reset;

            rg0_before = grants_per_core[0];
            rg1_before = grants_per_core[1];

            req_addr[0]  = 16'h0010;
            req_addr[1]  = 16'h0020;
            req_data[0]  = 16'h1111;
            req_data[1]  = 16'h2222;
            req_valid[0] = 1;
            req_valid[1] = 1;

            repeat (20) @(posedge clk);

            clear_requests;
            @(posedge clk);

            $display("Grants over 20 cycles: core0=%0d, core1=%0d",
                     grants_per_core[0] - rg0_before,
                     grants_per_core[1] - rg1_before);

            if ((grants_per_core[0] - rg0_before) < 8 ||
                (grants_per_core[0] - rg0_before) > 12) begin
                $error("Core 0 grants out of fair range");
                errors = errors + 1;
            end

            if ((grants_per_core[1] - rg1_before) < 8 ||
                (grants_per_core[1] - rg1_before) > 12) begin
                $error("Core 1 grants out of fair range");
                errors = errors + 1;
            end
        end
    endtask

    task test_no_starvation;
        integer served_in_cycle;
        integer c;
        begin
            $display("\nTEST: no starvation");
            do_reset;

            req_addr[0]  = 16'h0050;
            req_data[0]  = 16'hAAAA;
            req_addr[1]  = 16'h0060;
            req_data[1]  = 16'hBBBB;
            req_valid[0] = 1;

            repeat (5) @(posedge clk);

            req_valid[1] = 1;
            served_in_cycle = -1;

            for (c = 0; c < NUM_CORES * 2; c = c + 1) begin
                @(posedge clk);
                if (req_ready[1] && served_in_cycle < 0)
                    served_in_cycle = c;
            end

            clear_requests;

            if (served_in_cycle < 0) begin
                $error("Core 1 starved");
                errors = errors + 1;
            end else begin
                $display("PASS: Core 1 served within %0d cycles", served_in_cycle + 1);
            end
        end
    endtask

    task test_random_stress;
        input integer n_cycles;
        integer c;
        integer i;
        begin
            $display("\nTEST: random stress for %0d cycles", n_cycles);
            do_reset;

            for (c = 0; c < n_cycles; c = c + 1) begin
                for (i = 0; i < NUM_CORES; i = i + 1) begin
                    req_valid[i] = 1'($random);
                    req_addr[i]  = ADDR_WIDTH'($random);
                    req_data[i]  = DATA_WIDTH'($random);
                end
                @(posedge clk);
            end

            clear_requests;
            $display("PASS: random stress complete");
        end
    endtask

    initial begin
        $display("Starting rr_write_arbiter_tb");

        #10;

        test_solo_write;
        test_fairness;
        test_no_starvation;
        test_random_stress(200);

        $display("\n==============================");
        $display("Grant summary:");
        for (int i = 0; i < NUM_CORES; i++)
            $display("  core %0d: %0d grants, stall_cycles=%0d",
                     i, grants_per_core[i], stall_cycles);

        if (errors == 0)
            $display("ALL TESTS PASSED");
        else
            $display("FAIL: %0d errors", errors);

        $display("==============================");

        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "TIMEOUT");
    end

endmodule
