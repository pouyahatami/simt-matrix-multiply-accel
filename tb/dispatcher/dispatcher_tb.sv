`timescale 1ns/1ns //wjat does this do?


// the goal of this testbench is to pretend to be fake cores and respond to the dispachers signals 

// test plan:
// 1- all threads get assigned 
// 2- only one core at a time gets assigned
// 3- done signal goes up at the end 
// 4- the right thread ids and counts get assigned to each core
// 5- make sure that core_start[i] pules after handskahe 
// 6- blocks need to be assinged in the right order (for our case the first lowest indedx core dhould be servied fitrst )

module dispatcher_tb;


    // what is the difference between localparam and parameter?
    localparam NUM_CORES        = 2;
    localparam THREADS_PER_CORE = 2;

    //inputs to dispatcher
    logic clk, rst, start;
    logic [7:0] N;
    logic [NUM_CORES-1:0] core_done, core_ready;

    //outputs from dispatcher
    logic [NUM_CORES-1:0] core_valid, core_start;
    logic [15:0] core_thread_id    [NUM_CORES-1:0];
    logic [15:0] core_thread_count [NUM_CORES-1:0];
    logic done;

    int errors = 0;
    int total_threads_seen = 0;
    int expected_next_thread_id = 0;

    //dispatcher instance
    dispatcher #(
        .NUM_CORES(NUM_CORES),  
        .THREADS_PER_CORE(THREADS_PER_CORE)
    ) dut ( 
        .clk(clk),
        .rst(rst),
        .start(start),
        .N(N),
        .core_done(core_done),
        .core_ready(core_ready),
        .core_valid(core_valid),
        .core_start(core_start),
        .core_thread_id(core_thread_id),
        .core_thread_count(core_thread_count),
        .done(done)
    );

    //generate clk
    initial begin 
        clk = 0;
        forever begin
            #5 clk = ~clk; // 100 MHz
        end 
    end

    // If a core gets started, wait a few cycles, then pulse done.
    task automatic fake_core_done(input int core_id, input int delay_cycles);
        begin
            repeat (delay_cycles) @(posedge clk);
            core_done[core_id] = 1'b1;
            @(posedge clk);
            core_done[core_id] = 1'b0;
        end
    endtask

    // Check assignment when handshake happens
    //Keep running this behavior forever during simulation.
    always @(posedge clk) begin
        if (!rst) begin
            for (int i = 0; i < NUM_CORES; i++) begin
                if (core_valid[i] && core_ready[i]) begin

                    $display("Handshake core %0d: thread_id=%0d, count=%0d",
                             i, core_thread_id[i], core_thread_count[i]);

                    if (core_thread_id[i] !== expected_next_thread_id[15:0]) begin
                        $error("Wrong thread_id on core %0d: expected %0d, got %0d",
                               i, expected_next_thread_id, core_thread_id[i]);
                        errors++;
                    end

                    if (core_thread_count[i] > THREADS_PER_CORE) begin
                        $error("core_thread_count too large on core %0d: got %0d",
                               i, core_thread_count[i]);
                        errors++;
                    end

                    expected_next_thread_id += core_thread_count[i];
                    total_threads_seen      += core_thread_count[i];
                end
            end
        end
    end

    // Main test
    initial begin 

        rst = 1;
        N = 4; // test with 4x4 and 8x8 matrices
        start = 0;

        core_ready = 2'b11; // both fake cores are ready
        core_done  = 2'b00;

        repeat (2) @(posedge clk);

        rst = 0;

        @(posedge clk);
        start = 1;

        @(posedge clk);
        start = 0;

        // Wait for core_start pulses and finish fake cores
        fork
            begin
                forever begin
                    @(posedge clk);
                    if (core_start[0]) begin
                        fake_core_done(0, 3);
                    end
                end
            end

            begin
                forever begin
                    @(posedge clk);
                    if (core_start[1]) begin
                        fake_core_done(1, 5);
                    end
                end
            end
        join_none

        wait(done == 1'b1);

        @(posedge clk);

        if (total_threads_seen !== N * N) begin
            $error("Wrong total threads assigned: expected %0d, got %0d",
                   N * N, total_threads_seen);
            errors++;
        end

        if (errors == 0) begin
            $display("\n=== PASS ===");
        end else begin
            $display("\n=== FAIL: %0d errors ===", errors);
        end

        $finish;
    end

endmodule