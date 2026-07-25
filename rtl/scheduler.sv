// =============================================================================
// File:    scheduler.sv
//
// Module Description:
//   Kernel FSM for one core. Issues A/B read requests and C write requests
//   through the shared round-robin arbiters; stalls visibly on contention.
//
// FSM states:
//   IDLE → INIT → WAIT_AB (→ NEXT_T, NEXT_K) → WRITE_REQ (→ NEXT_W) → DONE_ST
// =============================================================================
module scheduler #(
    parameter THREADS_PER_CORE = 2,
    parameter TSEL             = (THREADS_PER_CORE == 1) ? 1 : $clog2(THREADS_PER_CORE)
)(
    input  logic                              clk,
    input  logic                              rst,
    input  logic                              start,

    // Kernel parameters
    input  logic [7:0]                        N,
    input  logic [7:0]                        thread_count,

    // To core
    output logic [TSEL-1:0]                   t_select,
    output logic [THREADS_PER_CORE-1:0]       data_valid,
    output logic [THREADS_PER_CORE-1:0]       fma_en,
    output logic [7:0]                        k,

    // Pulsed high for one cycle (the INIT cycle) at the start of every
    // kernel run — threads use it to reset their accumulator.
    output logic                              kernel_init,

    // ── Memory-controller handshake: A read channel ─────────────────────
    output logic                              a_req_valid,
    input  logic                              a_req_ready,
    input  logic                              a_resp_valid,

    // ── Memory-controller handshake: B read channel ─────────────────────
    output logic                              b_req_valid,
    input  logic                              b_req_ready,
    input  logic                              b_resp_valid,

    // ── Memory-controller handshake: C write channel ────────────────────
    output logic                              c_req_valid,
    input  logic                              c_req_ready,

    // Debug
    output logic [3:0]                        state,
    output logic [31:0]                       stall_cycles,

    output logic                              done
);

    // `done` must never overlap with `start`. The registered `done_r` below
    // only clears one cycle *after* start arrives (DONE_ST -> INIT is a
    // normal registered transition), which left a one-cycle window where
    // core_start=1 and core_done=1 were both true to the outside world.
    // The dispatcher's shadow core_busy bookkeeping (dispatcher.sv) samples
    // core_done every cycle and free's the core's slot on a 1->busy read of
    // done — during that overlap cycle it saw the stale done=1 and
    // incorrectly cleared core_busy right as the core began its *next*
    // kernel, causing the dispatcher to dispatch a third block on top of a
    // still-running second one (corrupting the live, unlatched
    // thread_id_start/thread_count inputs mid-kernel). Force `done` low
    // combinationally the instant `start` is observed so the overlap cannot
    // exist, regardless of internal register timing.
    logic done_r;
    assign done = done_r && !start;

    // State encoding
    localparam [3:0] IDLE      = 4'h0;
    localparam [3:0] INIT      = 4'h1;
    localparam [3:0] WAIT_AB   = 4'h2;
    localparam [3:0] NEXT_T    = 4'h4;
    localparam [3:0] NEXT_K    = 4'h5;
    localparam [3:0] WRITE_REQ = 4'h6;
    localparam [3:0] NEXT_W    = 4'h7;
    localparam [3:0] DONE_ST   = 4'h8;

    logic [7:0] t_cnt;
    logic [7:0] k_cnt;

    // Per-channel "have I got this operand yet" / "is my request currently
    // in flight (granted, awaiting response)" tracking.
    logic a_have, b_have;
    logic a_inflight, b_inflight;

    wire is_last_thread = (t_cnt == thread_count - 8'd1);
    wire is_last_k      = (k_cnt == N - 8'd1);

    // Request a channel only while we don't have its data yet and don't
    // already have a grant outstanding for it.
    assign a_req_valid = (state == WAIT_AB) && !a_have && !a_inflight;
    assign b_req_valid = (state == WAIT_AB) && !b_have && !b_inflight;
    assign c_req_valid = (state == WRITE_REQ);

    always_ff @(posedge clk) begin
        if (rst) begin
            state        <= IDLE;
            t_cnt        <= 0;
            k_cnt        <= 0;
            done_r       <= 1'b0;
            data_valid   <= 0;
            fma_en       <= 0;
            kernel_init  <= 1'b0;
            a_have       <= 1'b0;
            b_have       <= 1'b0;
            a_inflight   <= 1'b0;
            b_inflight   <= 1'b0;
            stall_cycles <= 32'd0;
        end else begin
            data_valid  <= 0;
            fma_en      <= 0;
            kernel_init <= 1'b0;

            // Grant -> inflight; response -> have. These run continuously
            // (gated by a_req_valid/b_req_valid being state-qualified above)
            // so they don't need to be repeated inside the case statement.
            if (a_req_valid && a_req_ready) a_inflight <= 1'b1;
            if (a_resp_valid) begin
                a_have     <= 1'b1;
                a_inflight <= 1'b0;
            end

            if (b_req_valid && b_req_ready) b_inflight <= 1'b1;
            if (b_resp_valid) begin
                b_have     <= 1'b1;
                b_inflight <= 1'b0;
            end

            // Contention metric: counting cycles where we're parked in
            // WAIT_AB or WRITE_REQ still waiting on memory.
            if ((state == WAIT_AB && !(a_have && b_have)) ||
                (state == WRITE_REQ && !c_req_ready))
                stall_cycles <= stall_cycles + 32'd1;

            case (state)
                IDLE: begin
                    done_r <= 1'b0;
                    if (start) begin
                        state       <= INIT;
                        kernel_init <= 1'b1;
                    end
                end

                INIT: begin
                    t_cnt      <= 0;
                    k_cnt      <= 0;
                    a_have     <= 1'b0;
                    b_have     <= 1'b0;
                    a_inflight <= 1'b0;
                    b_inflight <= 1'b0;
                    state      <= WAIT_AB;
                end

                WAIT_AB: begin
                    if (a_have && b_have) begin
                        data_valid[t_cnt[TSEL-1:0]] <= 1'b1;
                        fma_en    [t_cnt[TSEL-1:0]] <= 1'b1;
                        a_have <= 1'b0;
                        b_have <= 1'b0;
                        state  <= NEXT_T;
                    end
                end

                NEXT_T: begin
                    if (is_last_thread) begin
                        t_cnt <= 0;
                        state <= NEXT_K;
                    end 
                    else begin
                        t_cnt <= t_cnt + 8'd1;
                        state <= WAIT_AB;
                    end
                end

                NEXT_K: begin
                    if (is_last_k) begin
                        t_cnt <= 0;
                        state <= WRITE_REQ;
                    end 
                    
                    else begin
                        k_cnt <= k_cnt + 8'd1;
                        state <= WAIT_AB;
                    end
                end

                WRITE_REQ: begin
                    if (c_req_ready) begin
                        state <= NEXT_W;
                    end
                end

                NEXT_W: begin
                    if (is_last_thread) begin
                        state <= DONE_ST;
                    end else begin
                        t_cnt <= t_cnt + 8'd1;
                        state <= WRITE_REQ;
                    end
                end

                // Multi-block: re-enter INIT on a new start pulse
                DONE_ST: begin
                    done_r <= 1'b1;
                    if (start) begin
                        done_r      <= 1'b0;
                        state       <= INIT;
                        kernel_init <= 1'b1;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

    assign t_select = t_cnt[TSEL-1:0];
    assign k        = k_cnt;

endmodule
