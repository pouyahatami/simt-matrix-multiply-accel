// =============================================================================
// de1soc_top_tb.sv -- hardware-accurate testbench for the DE1-SoC board wrapper
//
// Unlike gpu_top_tb.sv (which uses dual_port_bram as the memory model),
// this testbench instantiates de1soc_top ITSELF, so the real Quartus
// altsyncram IPs (matrix_ab.v, matrix_c.v) are in the simulation loop
// instead of dual_port_bram. This is the controlled experiment for the
// hardware-only matrix-C corruption seen on the board: most C values
// correct but scrambled in position, two slots (idx 0, idx 8) showing an
// identical bogus 0x0004, and two expected values (C[1][3], C[3][3])
// missing entirely -- while ModelSim against dual_port_bram passes 100%.
//
// If this test also passes 100% clean, the corruption is NOT caused by a
// timing/latency mismatch in the IPs themselves, and the remaining
// suspects are the physical .sof/programming step or the JTAG sampling
// process (In-System Memory Content Editor) rather than the RTL or the
// IP configuration.
//
// Requires the altera_mf simulation library (bundled with ModelSim-Altera
// Edition; see modelsim.ini's `others = $MODEL_TECH/../modelsim.ini` global
// mapping) to elaborate the `altsyncram` megafunction inside matrix_ab.v /
// matrix_c.v. Run from a directory where "matrix_ab.mif" is resolvable
// (the IP's init_file is a relative path) -- easiest is to copy this .mif
// next to wherever you run vsim from, or run from DE1-Soc/.
// =============================================================================
`timescale 1ns/1ps

module de1soc_top_tb;

    localparam N_TEST = 4;

    logic        CLOCK_50;
    logic [3:0]  KEY;
    logic [9:0]  LEDR;
    logic [6:0]  HEX0, HEX1, HEX2, HEX3;

    // 50 MHz -> 20 ns period
    initial begin CLOCK_50 = 0; forever #10 CLOCK_50 = ~CLOCK_50; end

    // DUT: the actual board-level wrapper, real matrix_ab/matrix_c IPs included
    de1soc_top #(
        .N_MAT (N_TEST)
    ) dut (
        .CLOCK_50 (CLOCK_50),
        .KEY      (KEY),
        .LEDR     (LEDR),
        .HEX0     (HEX0),
        .HEX1     (HEX1),
        .HEX2     (HEX2),
        .HEX3     (HEX3)
    );

    // ── C-write monitor: same technique as gpu_top_tb.sv, but reading the
    // internal bram_c_addr/bram_c_wr_data/bram_c_wr_en signals straight off
    // de1soc_top's hierarchy (they're plain `logic`s inside the module, not
    // ports, but ModelSim allows hierarchical reference to internal signals
    // for exactly this kind of debug/verification use). This tells us
    // whether the GPU drives the correct write transactions into matrix_c
    // when matrix_ab/matrix_c's real timing is in the loop for A/B reads too.
    logic [15:0] model_C [0:255];
    int          errors          = 0;
    int          writes_observed = 0;

    initial begin
        for (int i = 0; i < 256; i++) model_C[i] = 16'hDEAD;
        fork
            forever begin
                @(posedge CLOCK_50);
                if (dut.bram_c_wr_en) begin
                    writes_observed++;
                    model_C[dut.bram_c_addr] = dut.bram_c_wr_data;
                    $display("  [t=%0t] bram_C[%0d] <= %0d (write #%0d)",
                             $time, dut.bram_c_addr, dut.bram_c_wr_data, writes_observed);
                end
            end
        join_none
    end

    // Software golden -- same A=B=[1..16] row-major data baked into
    // DE1-Soc/matrix_ab.mif (words 0..15 = A, words 16..31 = B).
    function automatic logic [15:0] compute_golden(input int row, col, NN);
        logic [15:0] acc = 0;
        for (int kk = 0; kk < NN; kk++)
            acc += 16'((row*NN + kk) + 1) * 16'((kk*NN + col) + 1);
        return acc;
    endfunction

    initial begin
        $dumpfile("de1soc_top_tb.vcd");
        $dumpvars(0, de1soc_top_tb);

        // KEY is active-low: idle high, press = drive low.
        KEY = 4'b1111;
        @(posedge CLOCK_50);

        $display("");
        $display("=== de1soc_top HARDWARE-ACCURATE TEST: %0dx%0d matmul (real matrix_ab/matrix_c IPs) ===",
                  N_TEST, N_TEST);
        $write("Expected C (from golden):");
        for (int r = 0; r < N_TEST; r++) begin
            $write("\n  row %0d:", r);
            for (int c = 0; c < N_TEST; c++) $write(" %5d", compute_golden(r, c, N_TEST));
        end
        $display("");

        // Reset: hold KEY[0] low (rst = ~KEY[0] = 1) for a few cycles.
        KEY[0] = 1'b0;
        repeat (5) @(posedge CLOCK_50);
        KEY[0] = 1'b1;
        @(posedge CLOCK_50);

        // Start: pulse KEY[1] low (start = ~KEY[1] = 1) for a couple cycles,
        // same as a real button press, then release.
        KEY[1] = 1'b0;
        repeat (2) @(posedge CLOCK_50);
        KEY[1] = 1'b1;

        fork
            begin
                wait (LEDR[0] == 1'b1);
                $display("[t=%0t] done asserted (LEDR[0])!", $time);
            end
            begin
                repeat (20000) @(posedge CLOCK_50);
                $error("TIMEOUT waiting for done");
                errors++;
            end
        join_any
        disable fork;
        repeat (5) @(posedge CLOCK_50);

        for (int row = 0; row < N_TEST; row++) begin
            for (int col = 0; col < N_TEST; col++) begin
                automatic int addr = row * N_TEST + col;
                automatic logic [15:0] expected = compute_golden(row, col, N_TEST);
                if (model_C[addr] !== expected) begin
                    $error("  FAIL  C[%0d][%0d] (addr %0d): expected %0d, got %0d",
                           row, col, addr, expected, model_C[addr]);
                    errors++;
                end else begin
                    $display("  PASS  C[%0d][%0d] = %0d", row, col, model_C[addr]);
                end
            end
        end

        if (writes_observed != N_TEST * N_TEST) begin
            $error("Wrong write count: expected %0d, got %0d", N_TEST*N_TEST, writes_observed);
            errors++;
        end

        $display("");
        $display("HEX latch (C[0][0] via hex_value): 0x%04h", dut.hex_value);

        $display("");
        if (errors == 0)
            $display("=== HARDWARE-ACCURATE TEST PASSED -- real IPs reproduce sim results cleanly ===");
        else
            $display("=== HARDWARE-ACCURATE TEST FAILED: %0d errors -- real IP timing diverges from dual_port_bram model ===", errors);
        $finish;
    end

    initial begin #500000; $fatal(1, "HARD TIMEOUT"); end

endmodule
