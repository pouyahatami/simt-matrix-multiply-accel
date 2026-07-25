# =============================================================================
# run_write.do — ModelSim script for rr_write_arbiter_tb
#
# Usage (from anywhere):
#   do [file normalize [file join [file dirname [info script]] run_write.do]]
# =============================================================================

set SCRIPT_DIR [file dirname [info script]]
set PROJ_ROOT  [file normalize "$SCRIPT_DIR/../.."]
set RTL_DIR    "$PROJ_ROOT/rtl"
set TB_DIR     "$SCRIPT_DIR"

cd $TB_DIR
puts "Working dir: [pwd]"

if {[file isdirectory work]} { vdel -lib work -all }
vlib work

puts "Compiling DUT:  $RTL_DIR/rr_write_arbiter.sv"
vlog -sv "$RTL_DIR/rr_write_arbiter.sv"

puts "Compiling TB:   $TB_DIR/rr_write_arbiter_tb.sv"
vlog -sv "$TB_DIR/rr_write_arbiter_tb.sv"

vsim -voptargs="+acc" work.rr_write_arbiter_tb

if {![batch_mode]} {
    add wave -divider "Top-level"
    add wave -position end sim:/rr_write_arbiter_tb/clk
    add wave -position end sim:/rr_write_arbiter_tb/rst

    add wave -divider "Core requests"
    add wave -position end sim:/rr_write_arbiter_tb/req_valid
    add wave -position end sim:/rr_write_arbiter_tb/req_ready
    add wave -position end sim:/rr_write_arbiter_tb/req_data

    add wave -divider "BRAM port"
    add wave -position end sim:/rr_write_arbiter_tb/bram_addr
    add wave -position end sim:/rr_write_arbiter_tb/bram_wr_data
    add wave -position end sim:/rr_write_arbiter_tb/bram_wr_en

    add wave -divider "Arbiter internals"
    add wave -position end sim:/rr_write_arbiter_tb/dut/ptr
    add wave -position end sim:/rr_write_arbiter_tb/dut/grant
    add wave -position end sim:/rr_write_arbiter_tb/dut/stall_cycles

    configure wave -timelineunits ns
}

run -all

puts ""
puts "Simulation complete. Browse waveforms or 'quit -f' to exit."
