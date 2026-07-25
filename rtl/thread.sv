// =============================================================================
// File:    thread.sv
//
// Module Description:
//   Computes one output element C[row][col] via address generation and FMA
//   accumulation across the K-dimension.
//
// Interface:
//   kernel_init resets the accumulator at the start of each kernel run.
//   en gates the FMA each cycle a new A/B data pair is presented.
// =============================================================================
module thread #(
    parameter DATA_WIDTH = 16,
    parameter ADDR_WIDTH = 16
)(
    input logic clk, rst, en,

    // One-cycle pulse from the scheduler at the start of every kernel
    // run. Resets the accumulator so a thread hardware instance that
    // gets re-assigned to a new (thread_id, C-element) pair across
    // back-to-back block dispatches doesn't keep stale partial sums.
    input logic kernel_init,

    input logic [7:0] N, k,
    input logic [15:0] thread_id,
    input logic [ADDR_WIDTH-1:0] base_addr_A, base_addr_B, base_addr_C,

    // Data from memory (valid/ready handshake)
    input logic data_valid,
    input logic [DATA_WIDTH-1:0] a_val, b_val,
    output logic data_ready,

    // Address generation
    output logic [ADDR_WIDTH-1:0] addr_A, addr_B, addr_C,

    // Accumulated result
    output logic [DATA_WIDTH-1:0] result
);

        // Instantiates: 1x fma
    logic [DATA_WIDTH-1:0] accumulator, fma_result;
    logic fma_valid_out;
    logic [7:0] row, col;

    fma #(
        .DATA_WIDTH(DATA_WIDTH)
    ) fma_inst (  
        .clk       (clk),  
        .rst       (rst),  
        .a         (a_val),  
        .b         (b_val),  
        .c         (accumulator),  
        .valid_in  (data_valid && en),  
        .result    (fma_result),  
        .valid_out (fma_valid_out)
    );


    always_comb begin  
        row = thread_id / N; // to know which row of the matrix
        col = thread_id % N; // to know which column of the matrix
    end
    
    always_comb begin 

        // skip row rows and take the kth element in that row
        addr_A = base_addr_A + (row * N) + k;

        // skip k rows and take the colth element in that row
        addr_B = base_addr_B + (k * N) + col;

        // same as A
        addr_C = base_addr_C + (row * N) + col;
    end

    //ACCUMULATOR AND RESULT MANAGEMENT
        // accumulator should store the partial sum across k iterations
        // and when k = N -1 which is the last iteration, the accumulator holds the final C[i][j] value as the final result for output
        
    always @(posedge clk) begin
        if(rst) begin
            accumulator <= '0;
            result <= '0;
            data_ready <= 1; // so its always ready for data
        end else if (kernel_init) begin
            // Synchronous per-kernel reset. Takes priority over `en` and any
            // FMA update so the new block always starts from a clean zero.
            accumulator <= '0;
            result      <= '0;
        end else if (en) begin //set by the scheduler

            //update the accumulator when fma completes
            if(fma_valid_out) begin
                accumulator <= fma_result;
            end

            //output the final result on last iteration
            if(k == N - 1 && fma_valid_out) begin
                result <= fma_result;
            end
        end
    end
endmodule