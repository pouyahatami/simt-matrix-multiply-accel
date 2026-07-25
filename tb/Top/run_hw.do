# =============================================================================
# run_hw.do — hardware-accurate testbench (de1soc_top_tb), real Quartus IPs
#
# Compiles de1soc_top.sv against the REAL matrix_ab.v / matrix_c.v altsyncram
# IPs (not dual_port_bram), to test whether the hardware-only matrix-C
# corruption is reproducible in simulation once real IP timing is in the
# loop for A/B reads and the C write. If this passes 100% clean while the
# board shows corruption, the bug is NOT in the IPs or the RTL -- look at
# the .sof/programming step or the JTAG sampling (In-System Memory Content
# Editor) instead.
#
# Usage: do "C:/Users/User/Desktop/Year 3/DE1-SoC-GPU/tb/Top/run_hw.do"
#
# If you already have another testbench loaded in this vsim session (e.g.
# from run.do), run `quit -sim` first -- vsim refuses to `cd` while a
# design is loaded.
#
# Requires altera_mf.v (see ALTERA_MF path below) to elaborate the
# `altsyncram` megafunction -- ModelSim-Altera Starter/ASE Edition does not
# ship this precompiled, so we compile the source directly. Adjust
# ALTERA_MF if your Quartus install path differs.
# =============================================================================

set PROJ_ROOT "C:/Users/User/Desktop/Year 3/DE1-SoC-GPU"
set TB_DIR    "$PROJ_ROOT/tb/Top"
set RTL_DIR   "$PROJ_ROOT/rtl"
set IP_DIR    "$PROJ_ROOT/DE1-Soc"

# ModelSim-Altera Starter Edition (the version bundled with Quartus Lite)
# does NOT ship the altera_mf primitive library precompiled, so the global
# modelsim.ini has no working mapping for `altsyncram` -- vsim fails with
# "(vsim-3033) Instantiation of 'altsyncram' failed. The design unit was not
# found." even though vlog compiled matrix_ab.v/matrix_c.v with 0 errors
# (vlog doesn't resolve the instance, only vsim/vopt do, at elaboration).
#
# Fix: compile the actual altera_mf.v SOURCE (ships with every Quartus
# install, simulation-model sources for all altsyncram/lpm/etc. primitives)
# straight into our own `work` library instead of depending on a
# precompiled mapping. Adjust this path if your Quartus version/edition
# installs somewhere other than the default below.
#
# Confirmed: the only altera_mf.v on this machine is the one bundled with
# the (pre-Cyclone-V) Quartus 9.0sp2 install. Its altsyncram simulation
# model is missing some newer per-port parameters (e.g. it flat-out
# rejects address_reg_a as an unresolved defparam in BIDIR_DUAL_PORT mode --
# see matrix_ab.v's comments). It's old, but it's what's available, and it
# elaborates fine as long as matrix_ab.v/matrix_c.v only use parameters it
# actually knows about.
set ALTERA_MF "C:/altera/90sp2/quartus/eda/sim_lib/altera_mf.v"

# matrix_ab's altsyncram instance loads "matrix_ab.mif" via a RELATIVE path
# at elaboration time, resolved relative to the simulator's working
# directory -- so we run from IP_DIR, not TB_DIR.
cd $IP_DIR
puts "Working dir: [pwd]"

if {[file isdirectory work]} { vdel -lib work -all }
vlib work

puts "Compiling RTL..."
vlog -sv "$RTL_DIR/fma.sv"
vlog -sv "$RTL_DIR/thread.sv"
vlog -sv "$RTL_DIR/rr_read_arbiter.sv"
vlog -sv "$RTL_DIR/rr_write_arbiter.sv"
vlog -sv "$RTL_DIR/scheduler.sv"
vlog -sv "$RTL_DIR/core.sv"
vlog -sv "$RTL_DIR/dispatcher.sv"
vlog -sv "$RTL_DIR/gpu_top.sv"

puts "Compiling altera_mf simulation models (for altsyncram)..."
if {![file exists $ALTERA_MF]} {
    error "altera_mf.v not found at $ALTERA_MF -- find yours under <quartus install>/eda/sim_lib/altera_mf.v and update ALTERA_MF at the top of this script."
}
vlog -sv $ALTERA_MF

puts "Compiling Quartus IPs (matrix_ab, matrix_c)..."
vlog -sv "$IP_DIR/matrix_ab.v"
vlog -sv "$IP_DIR/matrix_c.v"

puts "Compiling de1soc_top.sv and testbench..."
vlog -sv "$RTL_DIR/de1soc_top.sv"
vlog -sv "$TB_DIR/de1soc_top_tb.sv"

vsim -voptargs="+acc" work.de1soc_top_tb

if {![batch_mode]} {
    add wave -divider "Board I/O"
    add wave -position end sim:/de1soc_top_tb/CLOCK_50
    add wave -position end sim:/de1soc_top_tb/KEY
    add wave -position end sim:/de1soc_top_tb/LEDR

    add wave -divider "BRAM C (real matrix_c IP)"
    add wave -position end sim:/de1soc_top_tb/dut/bram_c_addr
    add wave -position end sim:/de1soc_top_tb/dut/bram_c_wr_data
    add wave -position end sim:/de1soc_top_tb/dut/bram_c_wr_en

    add wave -divider "BRAM A/B (real matrix_ab IP)"
    add wave -position end sim:/de1soc_top_tb/dut/bram_a_addr
    add wave -position end sim:/de1soc_top_tb/dut/bram_a_rd_data
    add wave -position end sim:/de1soc_top_tb/dut/bram_b_addr
    add wave -position end sim:/de1soc_top_tb/dut/bram_b_rd_data

    configure wave -timelineunits ns
}

run -all

puts ""
puts "Simulation complete. Browse waveforms or 'quit -f' to exit."
