# ============================================================
# run_gpu_fast.do
# Fast batch-style compile and run
# ============================================================

transcript on

if {[file exists work]} {
    vdel -lib work -all
}

vlib work
vmap work work

vlog -sv rtl/fma.sv
vlog -sv rtl/thread.sv
vlog -sv rtl/scheduler.sv
vlog -sv rtl/rr_read_arbiter.sv
vlog -sv rtl/rr_write_arbiter.sv
vlog -sv rtl/core.sv
vlog -sv rtl/dispatcher.sv
vlog -sv rtl/dual_port_bram.sv
# mem_controller.sv / gpu_mem_master.sv: rejected v1 designs, never wired
# into gpu_top -- moved to archives/rtl/, not compiled here anymore.
vlog -sv rtl/gpu_top.sv
vlog -sv rtl/de1soc_top.sv

vlog -sv tb/Top/gpu_top_tb.sv

vsim -voptargs=+acc work.gpu_top_tb
run -all