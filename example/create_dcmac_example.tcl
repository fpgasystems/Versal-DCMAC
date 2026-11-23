######################################################################################
# Example Vivado project for the dcmac hierarchy.
#
# Targets the AMD Versal V80, adds every HDL and XDC file shipped in the package,
# and runs bd_dcmac (flat) or dcmac_qsfp (wrapped qsfp_X_n_Y hier) depending on
# the wrap_qsfp arg. Stops once the BD wrapper is generated and set as top (no synthesis).
#
# Usage:
#   vivado -mode batch -source create_dcmac_example.tcl \
#          -tclargs <dcmac_index> <dual_dcmac> <dcmac_axil> <wrap_qsfp> <board> <nclk_f>
#
# Project name is fixed to "dcmac_example". All -tclargs are optional and positional. Defaults:
#   dcmac_index  = 0   (board+index resolves to a DCMAC site via board_config.tcl)
#   dual_dcmac   = 0   (0 -> single QSFP, 1 -> dual QSFP)
#   dcmac_axil   = 0   (0 -> AXI4-Lite tied off, 1 -> expose s_axi top-level
#                       port; clock+reset shared with aclk/aresetn)
#   wrap_qsfp    = 0   (0 -> flat top (Coyote-shaped), 1 -> wrap into a single
#                       qsfp_${2i}_n_${2i+1} hier with SLASH-aligned pin names)
#   board        = v80 (board key for the DCMAC site dict in board_config.tcl;
#                       only "v80" is defined today)
#   nclk_f       = 391 (DCMAC AXIS clock in MHz; mirrors Coyote's NCLK_F)
######################################################################################

set dcmac_index  0
set dual_dcmac   0
set dcmac_axil   0
set wrap_qsfp    0
set board        v80
set nclk_f       391

if {[llength $argv] >= 1} { set dcmac_index  [lindex $argv 0] }
if {[llength $argv] >= 2} { set dual_dcmac   [lindex $argv 1] }
if {[llength $argv] >= 3} { set dcmac_axil   [lindex $argv 2] }
if {[llength $argv] >= 4} { set wrap_qsfp    [lindex $argv 3] }
if {[llength $argv] >= 5} { set board        [lindex $argv 4] }
if {[llength $argv] >= 6} { set nclk_f       [lindex $argv 5] }

set part "xcv80-lsva4737-2MHP-e-S"

set script_dir [file dirname [file normalize [info script]]]
set pkg_root   [file normalize [file join $script_dir ".."]]
set build_dir  [file normalize [file join $script_dir "build" "dcmac_example"]]

puts "INFO: project_name = dcmac_example"
puts "INFO: part         = $part"
puts "INFO: dcmac_index  = $dcmac_index"
puts "INFO: dual_dcmac   = $dual_dcmac"
puts "INFO: dcmac_axil   = $dcmac_axil"
puts "INFO: wrap_qsfp    = $wrap_qsfp"
puts "INFO: board        = $board"
puts "INFO: nclk_f (MHz) = $nclk_f"
puts "INFO: pkg_root     = $pkg_root"
puts "INFO: build_dir    = $build_dir"

create_project dcmac_example $build_dir -part $part -force

# dcmac.tcl reads cnfg(nclk_f) (alias of cfg(nclk_f)) for the AXIS clock
# associated with s_axis_tx / m_axis_rx. No other cfg(*) keys are referenced.
set cfg(nclk_f) $nclk_f

set hdl_files [glob -nocomplain \
    [file join $pkg_root "hdl" "*.sv"] \
    [file join $pkg_root "hdl" "*.v"]]
if {[llength $hdl_files] == 0} {
    error "No HDL files found under [file join $pkg_root hdl]"
}
add_files -norecurse $hdl_files

set xdc_files [glob -nocomplain [file join $pkg_root "constraints" "*.xdc"]]
if {[llength $xdc_files] > 0} {
    add_files -fileset constrs_1 -norecurse $xdc_files
}

source [file join $pkg_root "tcl" "dcmac.tcl"]

if { $wrap_qsfp == 1 } {
    puts "Going via the QSFP hierarchy flow"
    bd_dcmac_qsfp "" $dcmac_index $dual_dcmac $dcmac_axil $board
} else {
    puts "Going via the flat hierarchy flow"
    bd_dcmac      "" $dcmac_index $dual_dcmac $dcmac_axil $board
}

set design_name "dcmac_${dcmac_index}_versal_axis_wrapper"
set bd_file [get_files "${design_name}.bd"]

# bd_dcmac / bd_dcmac_qsfp end with close_bd_design; re-open to externalize qsfp
# pins (wrap_qsfp flow only). validate_bd_design is intentionally NOT called: the
# FREQ_HZ on the promoted qsfp_gt_clk_0 port must be set after make_bd_intf_pins_external
# for Vivado to propagate it correctly into the GT clock chain.
if { $wrap_qsfp == 1 } {
    open_bd_design $bd_file
    set hier_name [get_bd_cells]
    make_bd_pins_external       [get_bd_cells ${hier_name}]
    make_bd_intf_pins_external  [get_bd_cells ${hier_name}]
    set_property CONFIG.FREQ_HZ 322265625 [get_bd_intf_ports -filter {VLNV =~ "*diff_clock*"}]
    set_property CONFIG.FREQ_HZ 100000000 [get_bd_ports -filter {NAME =~ "freerunning_clk*"}]
    set_property CONFIG.FREQ_HZ [expr {$nclk_f * 1000000}] [get_bd_ports -filter {NAME =~ "aclk*"}]
    save_bd_design
    close_bd_design $design_name
}

generate_target all $bd_file
set wrapper_v [make_wrapper -files $bd_file -top]
add_files -norecurse $wrapper_v
set_property top "${design_name}_wrapper" [current_fileset]
update_compile_order -fileset sources_1

puts "============================================================"
puts "INFO: project created at $build_dir/dcmac_example.xpr"
puts "INFO: block design     : $design_name"
puts "INFO: top              : ${design_name}_wrapper"
puts "INFO: open in GUI with : vivado $build_dir/dcmac_example.xpr"
puts "============================================================"
