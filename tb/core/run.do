# =============================================================================
# run.do — ModelSim script for Core_tb
#
# Usage (from anywhere):
#   do [file normalize [file join [file dirname [info script]] run.do]]
# =============================================================================

set SCRIPT_DIR [file dirname [info script]]
set PROJ_ROOT  [file normalize "$SCRIPT_DIR/../.."]
set RTL_DIR    "$PROJ_ROOT/rtl"
set TB_DIR     "$SCRIPT_DIR"

cd $TB_DIR
puts "Working dir: [pwd]"

if {[file isdirectory work]} { vdel -lib work -all }
vlib work

puts "Compiling RTL..."
vlog -sv "$RTL_DIR/fma.sv"
vlog -sv "$RTL_DIR/thread.sv"
vlog -sv "$RTL_DIR/scheduler.sv"
vlog -sv "$RTL_DIR/core.sv"

puts "Compiling TB: $TB_DIR/Core_tb.sv"
vlog -sv "$TB_DIR/Core_tb.sv"

vsim -voptargs="+acc" work.Core_tb

if {![batch_mode]} {
    add wave -divider "Control"
    add wave -position end sim:/Core_tb/clk
    add wave -position end sim:/Core_tb/rst
    add wave -position end sim:/Core_tb/valid
    add wave -position end sim:/Core_tb/ready
    add wave -position end sim:/Core_tb/start
    add wave -position end sim:/Core_tb/done

    add wave -divider "Block params"
    add wave -position end sim:/Core_tb/N
    add wave -position end sim:/Core_tb/thread_id_start
    add wave -position end sim:/Core_tb/thread_count

    add wave -divider "A channel"
    add wave -position end sim:/Core_tb/a_req_valid
    add wave -position end sim:/Core_tb/a_req_ready
    add wave -position end sim:/Core_tb/a_req_addr
    add wave -position end sim:/Core_tb/a_resp_valid
    add wave -position end sim:/Core_tb/a_resp_data

    add wave -divider "B channel"
    add wave -position end sim:/Core_tb/b_req_valid
    add wave -position end sim:/Core_tb/b_req_ready
    add wave -position end sim:/Core_tb/b_req_addr
    add wave -position end sim:/Core_tb/b_resp_valid
    add wave -position end sim:/Core_tb/b_resp_data

    add wave -divider "C channel"
    add wave -position end sim:/Core_tb/c_req_valid
    add wave -position end sim:/Core_tb/c_req_ready
    add wave -position end sim:/Core_tb/c_req_addr
    add wave -position end sim:/Core_tb/c_req_data

    add wave -divider "Debug"
    add wave -position end sim:/Core_tb/stall_cycles

    configure wave -timelineunits ns
}

run -all

puts ""
puts "Simulation complete. Browse waveforms or 'quit -f' to exit."
