# =============================================================================
# run.do — ModelSim script for scheduler_tb
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

puts "Compiling DUT:  $RTL_DIR/scheduler.sv"
vlog -sv "$RTL_DIR/scheduler.sv"

puts "Compiling TB:   $TB_DIR/scheduler_tb.sv"
vlog -sv "$TB_DIR/scheduler_tb.sv"

vsim -voptargs="+acc" work.scheduler_tb

if {![batch_mode]} {
    add wave -divider "Control"
    add wave -position end sim:/scheduler_tb/clk
    add wave -position end sim:/scheduler_tb/rst
    add wave -position end sim:/scheduler_tb/start
    add wave -position end sim:/scheduler_tb/done
    add wave -position end sim:/scheduler_tb/N
    add wave -position end sim:/scheduler_tb/thread_count

    add wave -divider "FSM"
    add wave -position end sim:/scheduler_tb/fsm_state
    add wave -position end sim:/scheduler_tb/stall_cycles
    add wave -position end sim:/scheduler_tb/kernel_init
    add wave -position end sim:/scheduler_tb/k
    add wave -position end sim:/scheduler_tb/t_select

    add wave -divider "A read channel"
    add wave -position end sim:/scheduler_tb/a_req_valid
    add wave -position end sim:/scheduler_tb/a_req_ready
    add wave -position end sim:/scheduler_tb/a_resp_valid

    add wave -divider "B read channel"
    add wave -position end sim:/scheduler_tb/b_req_valid
    add wave -position end sim:/scheduler_tb/b_req_ready
    add wave -position end sim:/scheduler_tb/b_resp_valid

    add wave -divider "C write channel"
    add wave -position end sim:/scheduler_tb/c_req_valid
    add wave -position end sim:/scheduler_tb/c_req_ready

    add wave -divider "Thread/FMA"
    add wave -position end sim:/scheduler_tb/data_valid
    add wave -position end sim:/scheduler_tb/fma_en

    configure wave -timelineunits ns
}

run -all

puts ""
puts "Simulation complete. Browse waveforms or 'quit -f' to exit."
