// =============================================================================
// File:    de1soc_top.sv
//
// Module Description:
//   Board-level wrapper for the DE1-SoC. Connects gpu_top to CLOCK_50, KEY,
//   LEDR, and HEX displays; instantiates the two Quartus memory IPs.
//
// I/O:
//   KEY[0]=reset, KEY[1]=start. LEDR[0]=done. HEX3..0: "DONE" or C[0][0].
// =============================================================================
`timescale 1ns/1ps

module de1soc_top #(
    parameter DATA_WIDTH       = 16,
    parameter ADDR_WIDTH       = 16,
    parameter NUM_CORES        = 4,
    parameter THREADS_PER_CORE = 2,
    parameter BRAM_DEPTH       = 256,
    parameter N_MAT            = 4     // matrix dimension for this build
) (
    input  logic         CLOCK_50,
    input  logic [3:0]   KEY,          // active-low
    output logic [9:0]   LEDR,
    output logic [6:0]   HEX0,
    output logic [6:0]   HEX1,
    output logic [6:0]   HEX2,
    output logic [6:0]   HEX3
);




    // ── Clock and reset ─────────────────────────────────────────────────
    logic clk;
    assign clk = CLOCK_50;

    logic rst;
    assign rst = ~KEY[0];   // press KEY[0] to reset (active-high inside the GPU)

    // KEY[1] = start. Holding it down is fine — gpu_top's dispatcher only
    // accepts start when it transitions IDLE → RUN, then ignores further
    // pulses until the kernel completes.
    logic start;
    assign start = ~KEY[1];

    // LEDR[1] lit while any core is stalled on memory contention
    logic any_core_stalling;

    // ── Kernel parameters (hardcoded for this hardware build) ──────────
    logic [7:0]              N           = N_MAT[7:0];
    logic [ADDR_WIDTH-1:0]   base_addr_A = '0;
    // A and B now share one physical dual-port BRAM (matrix_ab, see below),
    // so B must live at a disjoint offset within that same 256-word array.
    // base_addr_B = N*N puts B right after A's N*N words.
    logic [ADDR_WIDTH-1:0]   base_addr_B = ADDR_WIDTH'(N_MAT * N_MAT);
    logic [ADDR_WIDTH-1:0]   base_addr_C = '0;

    // ── Single shared BRAM port per matrix (arbitrated inside gpu_top) ──
    logic [ADDR_WIDTH-1:0]   bram_a_addr;
    logic                    bram_a_rd_en;
    logic [DATA_WIDTH-1:0]   bram_a_rd_data;

    logic [ADDR_WIDTH-1:0]   bram_b_addr;
    logic                    bram_b_rd_en;
    logic [DATA_WIDTH-1:0]   bram_b_rd_data;

    logic [ADDR_WIDTH-1:0]   bram_c_addr;
    logic [DATA_WIDTH-1:0]   bram_c_wr_data;
    logic                    bram_c_wr_en;

    logic done;

    // ── Debug counters from gpu_top ─────────────────────────────────────
    logic [31:0] a_grant_count [NUM_CORES-1:0];
    logic [31:0] b_grant_count [NUM_CORES-1:0];
    logic [31:0] c_grant_count [NUM_CORES-1:0];
    logic [31:0] a_stall_cycles, b_stall_cycles, c_stall_cycles;
    logic [31:0] core_stall_cycles [NUM_CORES-1:0];

    // ── GPU ─────────────────────────────────────────────────────────────
    gpu_top #(
        .DATA_WIDTH          (DATA_WIDTH),
        .ADDR_WIDTH          (ADDR_WIDTH),
        .NUM_CORES           (NUM_CORES),
        .THREADS_PER_CORE    (THREADS_PER_CORE),
        // matrix_ab (real altsyncram IP, BIDIR_DUAL_PORT) has a true
        // 2-cycle read latency (registered address + registered output)
        // that can't be configured down to 1 -- see matrix_ab.v and
        // rr_read_arbiter.sv for the full story. gpu_top_tb's
        // dual_port_bram-backed sim keeps the default of 1.
        .BRAM_READ_LATENCY   (2)
    ) u_gpu (
        .clk            (clk),
        .rst            (rst),
        .start          (start),
        .N              (N),
        .base_addr_A    (base_addr_A),
        .base_addr_B    (base_addr_B),
        .base_addr_C    (base_addr_C),

        .bram_a_addr    (bram_a_addr),
        .bram_a_rd_en   (bram_a_rd_en),
        .bram_a_rd_data (bram_a_rd_data),

        .bram_b_addr    (bram_b_addr),
        .bram_b_rd_en   (bram_b_rd_en),
        .bram_b_rd_data (bram_b_rd_data),

        .bram_c_addr    (bram_c_addr),
        .bram_c_wr_data (bram_c_wr_data),
        .bram_c_wr_en   (bram_c_wr_en),

        .done              (done),
        .a_grant_count     (a_grant_count),
        .b_grant_count     (b_grant_count),
        .c_grant_count     (c_grant_count),
        .a_stall_cycles    (a_stall_cycles),
        .b_stall_cycles    (b_stall_cycles),
        .c_stall_cycles    (c_stall_cycles),
        .core_stall_cycles (core_stall_cycles)
    );

    // ── Matrix A/B memory: one shared dual-port BRAM IP ─────────────────
    // matrix_ab (Quartus altsyncram megafunction, BIDIR_DUAL_PORT) is ONE
    // 256-word x 16-bit array with two independent access ports — not two
    // separate buffers. Port A reads matrix A starting at base_addr_A=0;
    // port B reads matrix B starting at base_addr_B=N*N, in the SAME
    // physical block. This genuinely uses both ports (vs. the old
    // dual_port_bram instances, which each only used port A and left port B
    // tied off). Preloaded from DE1-Soc/matrix_ab.mif at configuration time;
    // there is no runtime write path here (wren tied low) — reload the .mif
    // and recompile to change inputs.
    // NOTE: this particular wizard config of matrix_ab has no rden_a/rden_b
    // ports at all (read is implicitly always-on) — bram_a_rd_en/bram_b_rd_en
    // from gpu_top are simply left unconnected here.
    matrix_ab u_matrix_ab (
        .address_a (bram_a_addr[7:0]),
        .address_b (bram_b_addr[7:0]),
        .clock     (clk),
        .data_a    (16'd0),
        .data_b    (16'd0),
        .wren_a    (1'b0),
        .wren_b    (1'b0),
        .q_a       (bram_a_rd_data),
        .q_b       (bram_b_rd_data)
    );

    // ── BRAM C (output matrix C) ────────────────────────────────────────
    // matrix_c (Quartus altsyncram megafunction, SINGLE_PORT, ENABLE_RUNTIME_MOD=YES,
    // JTAG_ID="C") replaces the old dual_port_bram instance. Write side is
    // driven by gpu_top's write arbiter exactly as before. Host readback no
    // longer needs a wired-up port B: ENABLE_RUNTIME_MOD + JTAG_ENABLED makes
    // Quartus auto-insert a virtual-JTAG hub for this block, so it shows up
    // as "C" in Tools > In-System Memory Content Editor at runtime with no
    // extra top-level pins. q is unused here (GPU never reads C back).
    logic [DATA_WIDTH-1:0] bram_c_q_unused;
    matrix_c u_matrix_c (
        .address (bram_c_addr[7:0]),
        .clock   (clk),
        .data    (bram_c_wr_data),
        .rden    (1'b1),
        .wren    (bram_c_wr_en),
        .q       (bram_c_q_unused)
    );

    // Status LEDs
    assign LEDR[0]   = done;
   
    always_comb begin
        any_core_stalling = 1'b0;
        for (int i = 0; i < NUM_CORES; i++)
            if (core_stall_cycles[i] != 32'd0) any_core_stalling = 1'b1;
    end
    assign LEDR[1]   = any_core_stalling;
    assign LEDR[9:2] = 8'b0;

    // ── HEX displays: latch C[0][0] for visual verification ────────────
    // Holds 16'hDEAD until the first write to address 0 lands, then locks
    // onto that value. Lets you visually confirm the GPU computed the right
    // top-left output element.
    logic [15:0] hex_value;
    always_ff @(posedge clk) begin
        if (rst)
            hex_value <= 16'hDEAD;
        else if (bram_c_wr_en && (bram_c_addr == '0))
            hex_value <= bram_c_wr_data;
    end

    // Decode C[0][0]'s four hex nibbles as usual; these feed the muxes below.
    logic [6:0] hex0_digit, hex1_digit, hex2_digit, hex3_digit;
    seven_seg hd0 (.in(hex_value[3:0]),   .out(hex0_digit));
    seven_seg hd1 (.in(hex_value[7:4]),   .out(hex1_digit));
    seven_seg hd2 (.in(hex_value[11:8]),  .out(hex2_digit));
    seven_seg hd3 (.in(hex_value[15:12]), .out(hex3_digit));

    // While `done` is asserted -- it's a sticky level (dispatcher.sv's FSM
    // only clears it on the next `start` pulse, see the IDLE state; it does
    // NOT drop back to 0 on its own), not a single-cycle pulse -- override
    // all four displays to spell "DONE" instead of C[0][0]'s hex digits.
    // 'O' and 'N' aren't real hex digits, so they can't go through
    // seven_seg's 0-F decoder; their segment patterns are hardcoded here.
    // D and E reuse the exact same shapes seven_seg already draws for hex
    // digits 'd' and 'E'.
    localparam logic [6:0] SEG_D = 7'b0100001;  // same shape as hex digit 'd'
    localparam logic [6:0] SEG_O = 7'b1000000;  // same shape as hex digit '0'
    localparam logic [6:0] SEG_N = 7'b0101011;  // lowercase 'n'
    localparam logic [6:0] SEG_E = 7'b0000110;  // same shape as hex digit 'E'

    // HEX3 is the leftmost digit on the board, so HEX3..HEX0 = D,O,N,E reads
    // left-to-right as "DONE".
    assign HEX3 = done ? SEG_D : hex3_digit;
    assign HEX2 = done ? SEG_O : hex2_digit;
    assign HEX1 = done ? SEG_N : hex1_digit;
    assign HEX0 = done ? SEG_E : hex0_digit;

endmodule


// =============================================================================
// 7-segment decoder. DE1-SoC HEX displays are common-anode, so segments are
// active-low (0 = lit, 1 = dark). Bit order: out[6:0] = {g,f,e,d,c,b,a}.
// =============================================================================
module seven_seg (
    input  logic [3:0] in,
    output logic [6:0] out
);
    always_comb begin
        case (in)
            4'h0: out = 7'b1000000;
            4'h1: out = 7'b1111001;
            4'h2: out = 7'b0100100;
            4'h3: out = 7'b0110000;
            4'h4: out = 7'b0011001;
            4'h5: out = 7'b0010010;
            4'h6: out = 7'b0000010;
            4'h7: out = 7'b1111000;
            4'h8: out = 7'b0000000;
            4'h9: out = 7'b0010000;
            4'hA: out = 7'b0001000;
            4'hB: out = 7'b0000011;
            4'hC: out = 7'b1000110;
            4'hD: out = 7'b0100001;
            4'hE: out = 7'b0000110;
            4'hF: out = 7'b0001110;
            default: out = 7'b1111111;
        endcase
    end
endmodule
