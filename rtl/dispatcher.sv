// =============================================================================
// File:    dispatcher.sv 
//
// Module Description:
//   Hands out blocks to whichever core is free, one at a time, as cores free up
//
// Handshake: 
// dispatcher asserts core_valid[i] when block params are ready
// core asserts core_ready[i] when free; transfer completes on the cycle both
// are high; dispatcher then drops valid and pulses core_start for one cycle
// =============================================================================
module dispatcher #(
    parameter NUM_CORES        = 2,
    parameter THREADS_PER_CORE = 2
)(
    input  logic                       clk, rst, start,
    input  logic [7:0]                 N,
    input  logic [NUM_CORES-1:0]       core_done, core_ready,
 
    output logic [NUM_CORES-1:0]       core_valid, core_start,
    output logic [15:0]                core_thread_id [NUM_CORES-1:0],
    output logic [15:0]                core_thread_count    [NUM_CORES-1:0],
 
    output logic                       done
);
 
    localparam CORE_IDX_WIDTH = (NUM_CORES <= 1) ? 1 : $clog2(NUM_CORES);

    typedef enum logic [1:0] 
    { IDLE, RUN, FINISH } state_t;
    state_t state;


    //next thread to be assigned 
    logic [15:0]                 next_thread_id;

    logic [15:0]                 threads_remaining; //N*N
    logic [NUM_CORES-1:0]        core_busy;
 
  
    logic [NUM_CORES-1:0]        handshake;
    assign handshake = core_valid & core_ready; 
 
  
    // Combinational: pick the next core to assign
    // (lowest-index core that is free and has no pending valid)
    logic [CORE_IDX_WIDTH-1:0]           next_core_idx;
    logic                        any_cores_selected;
 

    // Priority encoder selects the next core to dispatch to.
    // Only one core is selected per cycle
    always_comb begin
        next_core_idx  = 0;
        // this signal is to differentiate between core0 being free vs core0 being busy 
        any_cores_selected = 1'b0; //? 

 
        // core_valid[i] is asserted when a core has been assigned a block
        for (int i = 0; i < NUM_CORES; i++) begin
            // A core is assignable if it's not busy, not currently being
            // handshaked and not just handshaking this cycle.
            if (!core_busy[i] && !core_valid[i] && !handshake[i]
                && !any_cores_selected) begin
                next_core_idx  = i[CORE_IDX_WIDTH-1:0];

                // only one core gets selected at a time 
                any_cores_selected = 1'b1;
            end
        end
    end
 
    logic [15:0] next_block_size;
    always_comb begin
        next_block_size = (threads_remaining >= 16'(THREADS_PER_CORE))
                          ? 16'(THREADS_PER_CORE)
                          : threads_remaining;
    end
 
    // FSM
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state              <= IDLE;
            next_thread_id     <= 0;
            threads_remaining  <= 16'(N)*16'(N); 
            core_busy          <= 0;
            core_valid         <= 0;
            core_start         <= 0;
            done               <= 0;
            
            // unpacked arrays need to be initialized with a default value
            core_thread_id    <= '{default: '0};
            core_thread_count <= '{default: '0};
            
        end else begin
            
            case (state)
              
                IDLE: begin
                    core_valid <= '0;
                    if (start) begin
                        done              <= 0;
                        next_thread_id    <= 0;
                        threads_remaining <= 16'(N) * 16'(N);
                        state             <= RUN;
                    end
                end
 
                RUN: begin
                    // Per-cycle behavior in RUN:
                    //   1. For any core whose handshake fires this cycle: drop valid, pulse start,
                    //      mark core as busy.
                    //   2. For any core whose done fires this cycle: mark core as free.
                    //   3. Pick the lowest-index free core (with no pending valid) and assign it
                    //      the next chunk of threads. Assign at most ONE core per cycle 
                    //   4. When all work has been handed out AND all cores are idle, go to FINISH.

                    core_start <= '0;

                    // Step 1: handle handshakes (drop valid, pulse start, mark busy)
                    for (int i = 0; i < NUM_CORES; i++) begin
                        if (handshake[i]) begin
                            core_valid[i] <= 1'b0;
                            core_start[i] <= 1'b1;
                            core_busy[i]  <= 1'b1;
                        end
                    end
 
                    // Step 2: handle completions
                    for (int i = 0; i < NUM_CORES; i++) begin
                        if (core_done[i] && !handshake[i]) begin
                            core_busy[i] <= 1'b0;
                        end
                    end
 
                    // Step 3: assign at most ONE new block this cycle
                    if (any_cores_selected && (threads_remaining > 16'd0)) begin
                        core_thread_id[next_core_idx] <= next_thread_id;
                        core_thread_count   [next_core_idx] <= next_block_size;
                        core_valid          [next_core_idx] <= 1'b1; //core has been asigned a block 
                        next_thread_id                      <= next_thread_id + next_block_size;
                        threads_remaining                   <= threads_remaining - next_block_size;
                    end
 
                    // Step 4: assert done when all work has been handed out AND all cores are idle
                    if (threads_remaining == 16'd0
                        && core_busy  == 0
                        && core_valid == 0) begin
                        state <= FINISH;
                    end
                end

                FINISH: begin
                    done <= 1'b1;
                    state <= IDLE;
                end
 
                default: state <= IDLE;
            endcase
        end
    end
 
endmodule