# =============================================================================
# run.do — system-level testbench for the full GPU (gpu_top_tb), v2
# (4-core shared-memory-controller architecture)
#
# Usage: do "C:/Users/User/Desktop/Year 3/DE1-SoC-GPU/tb/Top/run.do"
# This is the canonical run script: it lives next to the canonical
# gpu_top_tb.sv and compiles directly from the canonical rtl/. There is no
# duplicate RTL tree involved here.
# =============================================================================

# Hardcoded absolute paths (forward slashes — Tcl-safe)
set PROJ_ROOT "C:/Users/User/Desktop/Year 3/DE1-SoC-GPU"
set TB_DIR    "$PROJ_ROOT/tb/Top"
set RTL_DIR   "$PROJ_ROOT/rtl"

cd $TB_DIR
puts "Working dir: [pwd]"

# Clean work library
if {[file isdirectory work]} { vdel -lib work -all }
vlib work

# ── Compile all RTL sources (v2: shared memory controller, NUM_CORES-generic) ──
puts "Compiling RTL..."
vlog -sv "$RTL_DIR/fma.sv"
vlog -sv "$RTL_DIR/thread.sv"
vlog -sv "$RTL_DIR/dual_port_bram.sv"
vlog -sv "$RTL_DIR/rr_read_arbiter.sv"
vlog -sv "$RTL_DIR/rr_write_arbiter.sv"
vlog -sv "$RTL_DIR/scheduler.sv"
vlog -sv "$RTL_DIR/core.sv"
vlog -sv "$RTL_DIR/dispatcher.sv"
vlog -sv "$RTL_DIR/gpu_top.sv"
# mem_controller.sv / gpu_mem_master.sv: rejected v1 designs, never wired
# into gpu_top -- moved to archives/rtl/, not compiled here anymore.
vlog -sv "$RTL_DIR/de1soc_top.sv"

# ── Compile testbench ────────────────────────────────────────
puts "Compiling testbench..."
vlog -sv "$TB_DIR/gpu_top_tb.sv"

# ── Elaborate ────────────────────────────────────────────────
vsim -voptargs="+acc" work.gpu_top_tb

# ── Waveform setup (interactive only) ────────────────────────
if {![batch_mode]} {
    add wave -divider "Top-level control"
    add wave -position end sim:/gpu_top_tb/clk
    add wave -position end sim:/gpu_top_tb/rst
    add wave -position end sim:/gpu_top_tb/start
    add wave -position end sim:/gpu_top_tb/done
    add wave -position end sim:/gpu_top_tb/N

    add wave -divider "BRAM_A (input matrix A)"
    add wave -position end sim:/gpu_top_tb/bram_a_addr
    add wave -position end sim:/gpu_top_tb/bram_a_rd_en
    add wave -position end sim:/gpu_top_tb/bram_a_rd_data

    add wave -divider "BRAM_C (output matrix)"
    add wave -position end sim:/gpu_top_tb/bram_c_addr
    add wave -position end sim:/gpu_top_tb/bram_c_wr_data
    add wave -position end sim:/gpu_top_tb/bram_c_wr_en

    add wave -divider "Dispatcher state"
    add wave -position end sim:/gpu_top_tb/dut/u_dispatcher/state
    add wave -position end sim:/gpu_top_tb/dut/u_dispatcher/core_valid
    add wave -position end sim:/gpu_top_tb/dut/u_dispatcher/core_ready
    add wave -position end sim:/gpu_top_tb/dut/u_dispatcher/core_start
    add wave -position end sim:/gpu_top_tb/dut/u_dispatcher/core_done
    add wave -position end sim:/gpu_top_tb/dut/u_dispatcher/next_thread_id
    add wave -position end sim:/gpu_top_tb/dut/u_dispatcher/threads_remaining

    add wave -divider "A read arbiter (round-robin)"
    add wave -position end sim:/gpu_top_tb/dut/u_a_arbiter/ptr
    add wave -position end sim:/gpu_top_tb/dut/u_a_arbiter/grant
    add wave -position end sim:/gpu_top_tb/dut/u_a_arbiter/stall_cycles

    add wave -divider "C write arbiter (round-robin)"
    add wave -position end sim:/gpu_top_tb/dut/u_c_arbiter/grant
    add wave -position end sim:/gpu_top_tb/dut/u_c_arbiter/stall_cycles

    configure wave -timelineunits ns
}

# ── Run ──────────────────────────────────────────────────────
run -all

puts ""
puts "Simulation complete. Browse waveforms or 'quit -f' to exit."
