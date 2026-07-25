`timescale 1ns/1ps

// =============================================================================
// rr_read_arbiter_tb — unit test for v2 read arbiter (req_valid/ready + resp_valid)
//
// Behavioral BRAM model latency matches DUT BRAM_READ_LATENCY:
//   1 → dual_port_bram / sim
//   2 → matrix_ab / Quartus altsyncram (registered addr + registered output)
// =============================================================================
module rr_read_arbiter_tb;

    localparam DATA_WIDTH        = 16;
    localparam ADDR_WIDTH        = 16;
    localparam NUM_CORES         = 2;
    localparam BRAM_READ_LATENCY = 1;

    logic clk, rst;

    logic [NUM_CORES-1:0]   req_valid;
    logic [ADDR_WIDTH-1:0]  req_addr   [NUM_CORES-1:0];
    logic [NUM_CORES-1:0]   req_ready;
    logic [NUM_CORES-1:0]   resp_valid;
    logic [DATA_WIDTH-1:0]  resp_data  [NUM_CORES-1:0];

    logic [ADDR_WIDTH-1:0]  bram_addr;
    logic                   bram_rd_en;
    logic [DATA_WIDTH-1:0]  bram_rd_data;

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
            mem_storage[i] = DATA_WIDTH'(i * 2);
    end

    // 1-cycle read model (dual_port_bram)
    always @(posedge clk) begin
        if (bram_rd_en)
            bram_rd_data <= mem_storage[bram_addr[7:0]];
    end

    rr_read_arbiter #(
        .DATA_WIDTH        (DATA_WIDTH),
        .ADDR_WIDTH        (ADDR_WIDTH),
        .NUM_CORES         (NUM_CORES),
        .BRAM_READ_LATENCY (BRAM_READ_LATENCY)
    ) dut (
        .clk          (clk),
        .rst          (rst),
        .req_valid    (req_valid),
        .req_addr     (req_addr),
        .req_ready    (req_ready),
        .resp_valid   (resp_valid),
        .resp_data    (resp_data),
        .bram_addr    (bram_addr),
        .bram_rd_en   (bram_rd_en),
        .bram_rd_data (bram_rd_data),
        .grant_count  (grant_count),
        .stall_cycles (stall_cycles)
    );

    // Second instance for matrix_ab-style 2-cycle read timing
    logic [NUM_CORES-1:0]   l2_req_valid;
    logic [ADDR_WIDTH-1:0]  l2_req_addr   [NUM_CORES-1:0];
    logic [NUM_CORES-1:0]   l2_req_ready;
    logic [NUM_CORES-1:0]   l2_resp_valid;
    logic [DATA_WIDTH-1:0]  l2_resp_data  [NUM_CORES-1:0];
    logic [ADDR_WIDTH-1:0]  l2_bram_addr;
    logic                   l2_bram_rd_en;
    logic [DATA_WIDTH-1:0]  l2_bram_rd_data;
    logic [31:0]            l2_grant_count [NUM_CORES-1:0];
    logic [31:0]            l2_stall_cycles;
    logic [ADDR_WIDTH-1:0]  l2_raddr_d;
    logic                   l2_rst;

    // matrix_ab timing: addr registered on rd_en, data registered one cycle later
    always @(posedge clk) begin
        if (l2_bram_rd_en)
            l2_raddr_d <= l2_bram_addr;
        l2_bram_rd_data <= mem_storage[l2_raddr_d[7:0]];
    end

    rr_read_arbiter #(
        .DATA_WIDTH        (DATA_WIDTH),
        .ADDR_WIDTH        (ADDR_WIDTH),
        .NUM_CORES         (NUM_CORES),
        .BRAM_READ_LATENCY (2)
    ) dut_lat2 (
        .clk          (clk),
        .rst          (l2_rst),
        .req_valid    (l2_req_valid),
        .req_addr     (l2_req_addr),
        .req_ready    (l2_req_ready),
        .resp_valid   (l2_resp_valid),
        .resp_data    (l2_resp_data),
        .bram_addr    (l2_bram_addr),
        .bram_rd_en   (l2_bram_rd_en),
        .bram_rd_data (l2_bram_rd_data),
        .grant_count  (l2_grant_count),
        .stall_cycles (l2_stall_cycles)
    );

    initial begin
        integer i;
        for (i = 0; i < NUM_CORES; i = i + 1) begin
            grants_per_core[i] = 0;
            req_valid[i]       = 0;
            req_addr[i]        = 0;
            l2_req_valid[i]    = 0;
            l2_req_addr[i]     = 0;
        end
        l2_rst = 1;
    end

    always @(posedge clk) begin
        integer i;
        int     n_req;

        if (!rst) begin
            if ($countones(req_ready) > 1) begin
                $error("VIOLATION: multiple read grants");
                errors = errors + 1;
            end

            if ((req_ready & ~req_valid) != 0) begin
                $error("VIOLATION: read grant without request");
                errors = errors + 1;
            end

            n_req = $countones(req_valid);
            if (n_req == 1 && req_ready == 0) begin
                $error("VIOLATION: solo read request but no grant");
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

    task wait_resp;
        input  integer core_idx;
        output logic   got;
        integer timeout;
        begin
            got     = 1'b0;
            timeout = 0;
            while (!got && timeout < 20) begin
                if (resp_valid[core_idx])
                    got = 1'b1;
                else begin
                    @(posedge clk);
                    timeout = timeout + 1;
                end
            end
        end
    endtask

    task do_read_and_check;
        input integer          core_idx;
        input [ADDR_WIDTH-1:0] addr;
        input [DATA_WIDTH-1:0] expected;
        logic got;
        begin
            req_addr[core_idx]  = addr;
            req_valid[core_idx] = 1;

            @(posedge clk);

            if (!req_ready[core_idx]) begin
                while (!req_ready[core_idx]) @(posedge clk);
            end

            req_valid[core_idx] = 0;

            wait_resp(core_idx, got);

            if (!got) begin
                $error("Core %0d: no resp_valid for addr=0x%h", core_idx, addr);
                errors = errors + 1;
            end else if (resp_data[core_idx] !== expected) begin
                $error("Core %0d read[0x%h]: expected 0x%h, got 0x%h",
                       core_idx, addr, expected, resp_data[core_idx]);
                errors = errors + 1;
            end else begin
                $display("PASS: Core %0d read [0x%h] = 0x%h",
                         core_idx, addr, resp_data[core_idx]);
            end

            @(posedge clk);
        end
    endtask

    task test_solo_read;
        begin
            $display("\nTEST: solo reads (latency=%0d)", BRAM_READ_LATENCY);
            do_reset;

            do_read_and_check(0, 16'h0005, 16'h000A);
            clear_requests;
            @(posedge clk);

            do_read_and_check(1, 16'h000A, 16'h0014);
            clear_requests;
            @(posedge clk);

            do_read_and_check(0, 16'h0000, 16'h0000);
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

            req_addr[0]  = 16'h0001;
            req_addr[1]  = 16'h0002;
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

            req_addr[0]  = 16'h0003;
            req_addr[1]  = 16'h0004;
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
                end
                @(posedge clk);
            end

            clear_requests;
            $display("PASS: random stress complete");
        end
    endtask

    task test_latency2_solo;
        logic l2_got;
        integer c;
        begin
            $display("\nTEST: solo read with BRAM_READ_LATENCY=2");

            l2_req_addr[0]  = 16'h0007;
            l2_req_addr[1]  = 0;
            l2_req_valid[0] = 0;
            l2_req_valid[1] = 0;

            l2_rst = 1;
            repeat (3) @(posedge clk);
            l2_rst = 0;
            @(posedge clk);

            l2_req_valid[0] = 1;
            @(posedge clk);
            if (!l2_req_ready[0]) begin
                $error("Latency-2 DUT: expected grant on first cycle");
                errors = errors + 1;
            end
            l2_req_valid[0] = 0;

            l2_got = 1'b0;
            for (c = 0; c < 5 && !l2_got; c = c + 1) begin
                if (l2_resp_valid[0]) begin
                    l2_got = 1'b1;
                    if (l2_resp_data[0] !== 16'h000E) begin
                        $error("Latency-2 read: expected 0x000E, got 0x%h", l2_resp_data[0]);
                        errors = errors + 1;
                    end else begin
                        $display("PASS: latency-2 read [0x0007] = 0x%h", l2_resp_data[0]);
                    end
                end else
                    @(posedge clk);
            end

            if (!l2_got) begin
                $error("Latency-2 DUT: no resp_valid within 5 cycles");
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $display("Starting rr_read_arbiter_tb (BRAM_READ_LATENCY=%0d)", BRAM_READ_LATENCY);

        #10;

        test_solo_read;
        test_fairness;
        test_no_starvation;
        test_random_stress(200);
        test_latency2_solo;

        $display("\n==============================");
        $display("Grant summary (latency=%0d DUT):", BRAM_READ_LATENCY);
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
