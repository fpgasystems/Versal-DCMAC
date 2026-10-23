######################################################################################
# This file is part of Coyote <https://github.com/fpgasystems/Coyote>
#
# MIT Licence
# Copyright (c) 2026, Systems Group, ETH Zurich
# All rights reserved.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
######################################################################################

################################################################
# CHECK VIVADO VERSION CHECK
################################################################
# This BD only supports DCMAC v3.0+ which uses the new GT IP; only supported in Vivado 2025.1+
# DCMAC v3.0 is used for Vivado 2025.1; DCMAC v3.1 is used for Vivado 2025.2+
set scripts_vivado_version 2025.1
set current_vivado_version [version -short]

if { [string compare $current_vivado_version $scripts_vivado_version] < 0 } {
    catch {common::send_gid_msg -ssname BD::TCL -id 2042 -severity "ERROR" \
        "This script requires Vivado $scripts_vivado_version or newer \
        but is being run in Vivado $current_vivado_version."}
    return 1
}

##################################################################
# CHECK Modules
##################################################################
set bCheckModules 1
set bCheckIPsPassed 1
if { $bCheckModules == 1 } {
   set list_check_mods "\
dcmac200g_ctl_port\
axis_seg_to_unseg_converter\
axis_unseg_to_seg_converter\
clk_to_flexif_clk\
clk_to_alt_serdes_clk\
clk_to_serdes_clk\
clk_to_ts_clk\
dcmac_reset_ctrl_wrapper\
"
    set list_mods_missing ""
    common::send_gid_msg -ssname BD::TCL -id 2020 -severity "INFO" "Checking if the following modules exist in the project's sources: $list_check_mods ."

    foreach mod_vlnv $list_check_mods {
        if { [can_resolve_reference $mod_vlnv] == 0 } {
            lappend list_mods_missing $mod_vlnv
        }
    }

    if { $list_mods_missing ne "" } {
        catch {common::send_gid_msg -ssname BD::TCL -id 2021 -severity "ERROR" "The following module(s) are not found in the project: $list_mods_missing" }
        common::send_gid_msg -ssname BD::TCL -id 2022 -severity "INFO" "Please add source files for the missing module(s) above."
        set bCheckIPsPassed 0
    }
}

if { $bCheckIPsPassed != 1 } {
   common::send_gid_msg -ssname BD::TCL -id 2023 -severity "WARNING" "Will not continue with creation of design due to the error(s) above."
   return 3
}

##################################################################
# BOARD CONFIG
##################################################################
# Per-board DCMAC site placement
# board_config.tcl: defines the global `_dcmac_board_loc` dict keyed on (board, dcmac_index) → DCMAC site.
source [file join [file dirname [info script]] board_config.tcl]

##################################################################
# DCMAC CONSTANTS
##################################################################
# GT reference clock for DCMAC (200GAUI-4 / RS544 FEC on V80).
# Single source of truth — replace every literal 322265625 / 322.265625 in this
# file. The QUAD*_REFCLK_STRING values are intentionally NOT parameterized: they
# embed Vivado's internal sub-Hz precision suffix (322.265625183611) and act as
# IP-internal keys, not user-facing frequencies.
set ::dcmac_gt_refclk_hz   322265625
set ::dcmac_gt_refclk_mhz  322.265625

##################################################################
# CONTEXT-AWARE HELPERS
##################################################################

# Returns 1 if a BD design is currently open in the Vivado session, 0 otherwise.
# Used by bd_dcmac and bd_dcmac_qsfp to switch between standalone mode
# (own the BD lifecycle, expose external ports) and inline mode (caller owns
# the BD, expose hier interface pins).
#
# `current_bd_design -quiet` returns the current BD design or empty string when
# none is open, without emitting a warning. `get_bd_designs` and the unqualified
# `current_bd_design` both emit BD 5-229 to the Vivado log when no BD exists,
# even when wrapped in `catch` — Vivado's logging is independent of Tcl errors.
proc _dcmac_bd_open {} {
    return [expr {[current_bd_design -quiet] ne ""}]
}

# Mode-aware boundary primitives. In inline mode, use create_bd_intf_pin /
# create_bd_pin (hier interface pins). In standalone mode, use the equivalent
# port primitives (BD root external ports).
proc _bnd_intf { inline args } {
    if { $inline } { return [create_bd_intf_pin {*}$args] }
    return [create_bd_intf_port {*}$args]
}
proc _bnd_pin { inline args } {
    if { $inline } { return [create_bd_pin {*}$args] }
    return [create_bd_port {*}$args]
}

##################################################################
# DESIGN PROCs
##################################################################

# Hierarchical cell: bd_clock_reset_ctrl
proc create_hier_cell_bd_clock_reset_ctrl { parentCell nameHier } {

  variable script_folder

  if { $parentCell eq "" || $nameHier eq "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2092 -severity "ERROR" "create_hier_cell_bd_clock_reset_ctrl() - Empty argument(s)!"}
     return
  }

  # Get object for parentCell
  set parentObj [get_bd_cells $parentCell]
  if { $parentObj == "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2090 -severity "ERROR" "Unable to find parent cell <$parentCell>!"}
     return
  }

  # Make sure parentObj is hier blk
  set parentType [get_property TYPE $parentObj]
  if { $parentType ne "hier" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2091 -severity "ERROR" "Parent <$parentObj> has TYPE = <$parentType>. Expected to be <hier>."}
     return
  }

  # Save current instance; Restore later
  set oldCurInst [current_bd_instance .]

  # Set parent object as current
  current_bd_instance $parentObj

  # Create cell and set as current instance
  set hier_obj [create_bd_cell -type hier $nameHier]
  current_bd_instance $hier_obj

  # Create interface pins
  create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 qsfp_gt_clk

  # Create pins
  create_bd_pin -dir O -from 0 -to 0 -type clk gt_ref_clk
  create_bd_pin -dir O -type clk dcmac_core_clk
  create_bd_pin -dir O -type clk dcmac_axis_clk
  create_bd_pin -dir O -type rst gt_reset
  create_bd_pin -dir I gt_reset_done_rx
  create_bd_pin -dir I gt_reset_done_tx
  create_bd_pin -dir O -type rst tx_core_reset
  create_bd_pin -dir O -from 5 -to 0 tx_chan_flush
  create_bd_pin -dir O -from 5 -to 0 -type rst tx_serdes_reset
  create_bd_pin -dir O -from 5 -to 0 rx_chan_flush
  create_bd_pin -dir O -type rst rx_core_reset
  create_bd_pin -dir O -from 5 -to 0 -type rst rx_serdes_reset
  create_bd_pin -dir I -type rst aresetn
  create_bd_pin -dir O -type rst axis_resetn
  create_bd_pin -dir O -type clk sys_clk

  # Create instance: diff_buff, and set properties
  set diff_buff [ create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf:2.2 diff_buff ]
  set_property CONFIG.C_BUF_TYPE {IBUFDS_GTME5} $diff_buff


  # Create instance: bufgt_dcmac, and set properties
  set bufgt_dcmac [ create_bd_cell -type ip -vlnv xilinx.com:ip:bufg_gt:1.0 bufgt_dcmac ]

  # Create instance: const_1, and set properties
  set const_1 [ create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_1 ]
  set_property CONFIG.CONST_VAL {1} $const_1


  # Create instance: clk_wizard_dcmac, and set properties
  set clk_wizard_dcmac [ create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wizard:1.0 clk_wizard_dcmac ]
  set_property -dict [list \
    CONFIG.CLKOUT_DRIVES {BUFG,BUFG,BUFG,BUFG,BUFG,BUFG,BUFG} \
    CONFIG.CLKOUT_DYN_PS {None,None,None,None,None,None,None} \
    CONFIG.CLKOUT_GROUPING {Auto,Auto,Auto,Auto,Auto,Auto,Auto} \
    CONFIG.CLKOUT_MATCHED_ROUTING {false,false,false,false,false,false,false} \
    CONFIG.CLKOUT_PORT {clk_out1,clk_out2,clk_out3,clk_out4,clk_out5,clk_out6,clk_out7} \
    CONFIG.CLKOUT_REQUESTED_DUTY_CYCLE {50.000,50.000,50.000,50.000,50.000,50.000,50.000} \
    CONFIG.CLKOUT_REQUESTED_OUT_FREQUENCY {782,390.625,100,100.000,100.000,100.000,100.000} \
    CONFIG.CLKOUT_REQUESTED_PHASE {0.000,0.000,0.000,0.000,0.000,0.000,0.000} \
    CONFIG.CLKOUT_USED {true,true,true,false,false,false,false} \
    CONFIG.OVERRIDE_PRIMITIVE {false} \
    CONFIG.PRIM_IN_FREQ $::dcmac_gt_refclk_mhz \
    CONFIG.PRIM_SOURCE {Global_buffer} \
    CONFIG.USE_LOCKED {false} \
  ] $clk_wizard_dcmac


  # Create instance: dcmac_reset_ctrl, and set properties
  set block_name dcmac_reset_ctrl_wrapper
  set block_cell_name dcmac_reset_ctrl
  if { [catch {set dcmac_reset_ctrl [create_bd_cell -type module -reference $block_name $block_cell_name] } errmsg] } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2095 -severity "ERROR" "Unable to add referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   } elseif { $dcmac_reset_ctrl eq "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2096 -severity "ERROR" "Unable to referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   }

  # Create interface connections
  connect_bd_intf_net -intf_net Conn1 [get_bd_intf_pins diff_buff/CLK_IN_D1] [get_bd_intf_pins qsfp_gt_clk]

  # Create port connections
  connect_bd_net -net aresetn_1  [get_bd_pins aresetn] [get_bd_pins dcmac_reset_ctrl/async_resetn]
  connect_bd_net -net bufgt_dcmac_usrclk  [get_bd_pins bufgt_dcmac/usrclk] [get_bd_pins clk_wizard_dcmac/clk_in1]
  connect_bd_net [get_bd_pins clk_wizard_dcmac/clk_out1] [get_bd_pins dcmac_core_clk] [get_bd_pins dcmac_reset_ctrl/dcmac_core_clk]
  connect_bd_net [get_bd_pins clk_wizard_dcmac/clk_out2] [get_bd_pins dcmac_axis_clk] [get_bd_pins dcmac_reset_ctrl/dcmac_axis_clk]
  connect_bd_net -net clk_wizard_dcmac_clk_out3  [get_bd_pins clk_wizard_dcmac/clk_out3] [get_bd_pins sys_clk] [get_bd_pins dcmac_reset_ctrl/sys_clk]
  connect_bd_net -net const_1_dout  [get_bd_pins const_1/dout] [get_bd_pins bufgt_dcmac/gt_bufgtce]
  connect_bd_net -net dcmac_reset_ctrl_axis_resetn  [get_bd_pins dcmac_reset_ctrl/axis_resetn] [get_bd_pins axis_resetn]
  connect_bd_net -net dcmac_reset_ctrl_gt_reset  [get_bd_pins dcmac_reset_ctrl/gt_reset] [get_bd_pins gt_reset]
  connect_bd_net -net dcmac_reset_ctrl_rx_chan_flush  [get_bd_pins dcmac_reset_ctrl/rx_chan_flush] [get_bd_pins rx_chan_flush]
  connect_bd_net -net dcmac_reset_ctrl_rx_core_reset  [get_bd_pins dcmac_reset_ctrl/rx_core_reset] [get_bd_pins rx_core_reset]
  connect_bd_net -net dcmac_reset_ctrl_rx_serdes_reset  [get_bd_pins dcmac_reset_ctrl/rx_serdes_reset] [get_bd_pins rx_serdes_reset]
  connect_bd_net -net dcmac_reset_ctrl_tx_chan_flush  [get_bd_pins dcmac_reset_ctrl/tx_chan_flush] [get_bd_pins tx_chan_flush]
  connect_bd_net -net dcmac_reset_ctrl_tx_core_reset  [get_bd_pins dcmac_reset_ctrl/tx_core_reset] [get_bd_pins tx_core_reset]
  connect_bd_net -net dcmac_reset_ctrl_tx_serdes_reset  [get_bd_pins dcmac_reset_ctrl/tx_serdes_reset] [get_bd_pins tx_serdes_reset]
  connect_bd_net -net diff_buff_IBUFDS_GTME5_O  [get_bd_pins diff_buff/IBUFDS_GTME5_O] [get_bd_pins gt_ref_clk]
  connect_bd_net -net diff_buff_IBUFDS_GTME5_ODIV2  [get_bd_pins diff_buff/IBUFDS_GTME5_ODIV2] [get_bd_pins bufgt_dcmac/outclk]
  connect_bd_net -net gt_reset_done_rx_1  [get_bd_pins gt_reset_done_rx] [get_bd_pins dcmac_reset_ctrl/gt_reset_done_rx]
  connect_bd_net -net gt_reset_done_tx_1  [get_bd_pins gt_reset_done_tx] [get_bd_pins dcmac_reset_ctrl/gt_reset_done_tx]

  # Restore current instance
  current_bd_instance $oldCurInst
}

# Hierarchical cell: datapath_rx
# dcmac_index is accepted for symmetry with create_hier_cell_dcmac_wrapper and
# is intended to be reflected in the caller-supplied $nameHier (e.g. "datapath_rx_0").
proc create_hier_cell_datapath_rx { parentCell nameHier {dcmac_index 0} } {

  variable script_folder

  if { $parentCell eq "" || $nameHier eq "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2092 -severity "ERROR" "create_hier_cell_datapath_rx() - Empty argument(s)!"}
     return
  }
  if {![string is integer -strict $dcmac_index] || !($dcmac_index == 0 || $dcmac_index == 1)} {
     catch {common::send_gid_msg -ssname BD::TCL -id 2092 -severity "ERROR" \
        "create_hier_cell_datapath_rx() - dcmac_index (value: $dcmac_index) must be 0 or 1"}
     return
  }

  # Get object for parentCell
  set parentObj [get_bd_cells $parentCell]
  if { $parentObj == "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2090 -severity "ERROR" "Unable to find parent cell <$parentCell>!"}
     return
  }

  # Make sure parentObj is hier blk
  set parentType [get_property TYPE $parentObj]
  if { $parentType ne "hier" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2091 -severity "ERROR" "Parent <$parentObj> has TYPE = <$parentType>. Expected to be <hier>."}
     return
  }

  # Save current instance; Restore later
  set oldCurInst [current_bd_instance .]

  # Set parent object as current
  current_bd_instance $parentObj

  # Create cell and set as current instance
  set hier_obj [create_bd_cell -type hier $nameHier]
  current_bd_instance $hier_obj

  # Create interface pins
  create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:axis_rtl:1.0 m_axis_rx

  create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:axis_rtl:1.0 s_axis_rx

  # Create pins
  create_bd_pin -dir I -type clk aclk
  create_bd_pin -dir I -type clk dclk
  create_bd_pin -dir I -type rst dresetn

  # Create instance: rx_dwc_1024_to_512, and set properties
  set rx_dwc_1024_to_512 [ create_bd_cell -type ip -vlnv xilinx.com:ip:axis_dwidth_converter:1.1 rx_dwc_1024_to_512 ]
  set_property -dict [list \
    CONFIG.HAS_TKEEP {1} \
    CONFIG.HAS_TLAST {1} \
    CONFIG.HAS_TSTRB {0} \
    CONFIG.M_TDATA_NUM_BYTES {64} \
    CONFIG.S_TDATA_NUM_BYTES {128} \
    CONFIG.TUSER_BITS_PER_BYTE {1} \
  ] $rx_dwc_1024_to_512

  # Create instance: rx_cdc_fifo, and set properties
  set rx_cdc_fifo [ create_bd_cell -type ip -vlnv xilinx.com:ip:axis_data_fifo:2.0 rx_cdc_fifo ]
  set_property -dict [list \
    CONFIG.FIFO_DEPTH {1024} \
    CONFIG.FIFO_MODE {1} \
    CONFIG.HAS_TKEEP {1} \
    CONFIG.HAS_TLAST {1} \
    CONFIG.IS_ACLK_ASYNC {1} \
    CONFIG.TDATA_NUM_BYTES {64} \
  ] $rx_cdc_fifo

  # Create instance: rx_reg_slice, and set properties
  set rx_reg_slice [ create_bd_cell -type ip -vlnv xilinx.com:ip:axis_register_slice:1.1 rx_reg_slice ]
  set_property CONFIG.REG_CONFIG {16} $rx_reg_slice

  # Create interface connections
  connect_bd_intf_net -intf_net Conn1 [get_bd_intf_pins rx_cdc_fifo/M_AXIS] [get_bd_intf_pins m_axis_rx]
  connect_bd_intf_net -intf_net S_AXIS_1 [get_bd_intf_pins s_axis_rx] [get_bd_intf_pins rx_dwc_1024_to_512/S_AXIS]
  connect_bd_intf_net -intf_net rx_dwc_1024_to_512_M_AXIS [get_bd_intf_pins rx_dwc_1024_to_512/M_AXIS] [get_bd_intf_pins rx_reg_slice/S_AXIS]
  connect_bd_intf_net -intf_net rx_reg_slice_M_AXIS [get_bd_intf_pins rx_reg_slice/M_AXIS] [get_bd_intf_pins rx_cdc_fifo/S_AXIS]

  # Create port connections
  connect_bd_net -net aclk1_1  [get_bd_pins dclk] \
    [get_bd_pins rx_dwc_1024_to_512/aclk] \
    [get_bd_pins rx_cdc_fifo/s_axis_aclk] \
    [get_bd_pins rx_reg_slice/aclk]
  connect_bd_net -net aclk_1  [get_bd_pins aclk] [get_bd_pins rx_cdc_fifo/m_axis_aclk]
  connect_bd_net -net aresetn_1  [get_bd_pins dresetn] \
    [get_bd_pins rx_dwc_1024_to_512/aresetn] \
    [get_bd_pins rx_cdc_fifo/s_axis_aresetn] \
    [get_bd_pins rx_reg_slice/aresetn]

  # Restore current instance
  current_bd_instance $oldCurInst
}

# Hierarchical cell: datapath_tx
# dcmac_index is accepted for symmetry with create_hier_cell_dcmac_wrapper and
# is intended to be reflected in the caller-supplied $nameHier (e.g. "datapath_tx_0").
proc create_hier_cell_datapath_tx { parentCell nameHier {dcmac_index 0} } {

  variable script_folder

  if { $parentCell eq "" || $nameHier eq "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2092 -severity "ERROR" "create_hier_cell_datapath_tx() - Empty argument(s)!"}
     return
  }
  if {![string is integer -strict $dcmac_index] || !($dcmac_index == 0 || $dcmac_index == 1)} {
     catch {common::send_gid_msg -ssname BD::TCL -id 2092 -severity "ERROR" \
        "create_hier_cell_datapath_tx() - dcmac_index (value: $dcmac_index) must be 0 or 1"}
     return
  }

  # Get object for parentCell
  set parentObj [get_bd_cells $parentCell]
  if { $parentObj == "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2090 -severity "ERROR" "Unable to find parent cell <$parentCell>!"}
     return
  }

  # Make sure parentObj is hier blk
  set parentType [get_property TYPE $parentObj]
  if { $parentType ne "hier" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2091 -severity "ERROR" "Parent <$parentObj> has TYPE = <$parentType>. Expected to be <hier>."}
     return
  }

  # Save current instance; Restore later
  set oldCurInst [current_bd_instance .]

  # Set parent object as current
  current_bd_instance $parentObj

  # Create cell and set as current instance
  set hier_obj [create_bd_cell -type hier $nameHier]
  current_bd_instance $hier_obj

  # Create interface pins
  create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:axis_rtl:1.0 s_axis_tx

  create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:axis_rtl:1.0 m_axis_tx

  # Create pins
  create_bd_pin -dir I -type rst aresetn
  create_bd_pin -dir I -type clk aclk
  create_bd_pin -dir I -type clk dclk
  create_bd_pin -dir I -type rst dresetn

  # Create instance: tx_cdc_fifo, and set properties
  set tx_cdc_fifo [ create_bd_cell -type ip -vlnv xilinx.com:ip:axis_data_fifo:2.0 tx_cdc_fifo ]
  set_property -dict [list \
    CONFIG.FIFO_DEPTH {256} \
    CONFIG.FIFO_MODE {2} \
    CONFIG.HAS_TKEEP {1} \
    CONFIG.IS_ACLK_ASYNC {1} \
    CONFIG.TDATA_NUM_BYTES {64} \
  ] $tx_cdc_fifo

  # Create instance: tx_reg_slice, and set properties
  set tx_reg_slice [ create_bd_cell -type ip -vlnv xilinx.com:ip:axis_register_slice:1.1 tx_reg_slice ]
  set_property CONFIG.REG_CONFIG {16} $tx_reg_slice

  # Create interface connections
  connect_bd_intf_net -intf_net Conn1 [get_bd_intf_pins tx_cdc_fifo/S_AXIS] [get_bd_intf_pins s_axis_tx]
  connect_bd_intf_net -intf_net axis_register_slice_0_M_AXIS [get_bd_intf_pins m_axis_tx] [get_bd_intf_pins tx_reg_slice/M_AXIS]
  connect_bd_intf_net -intf_net tx_cdc_fifo_M_AXIS [get_bd_intf_pins tx_cdc_fifo/M_AXIS] [get_bd_intf_pins tx_reg_slice/S_AXIS]

  # Create port connections
  connect_bd_net -net aclk_1  [get_bd_pins aclk]  [get_bd_pins tx_cdc_fifo/s_axis_aclk]
  connect_bd_net -net aresetn1_1  [get_bd_pins dresetn] [get_bd_pins tx_reg_slice/aresetn]
  connect_bd_net -net aresetn_1  [get_bd_pins aresetn] [get_bd_pins tx_cdc_fifo/s_axis_aresetn]
  connect_bd_net -net m_axis_aclk_1  [get_bd_pins dclk] \
    [get_bd_pins tx_cdc_fifo/m_axis_aclk] \
    [get_bd_pins tx_reg_slice/aclk]

  # Restore current instance
  current_bd_instance $oldCurInst
}

# Hierarchical cell: dcmac_wrapper
proc create_hier_cell_dcmac_wrapper { parentCell nameHier {dcmac_index 0} {dual_dcmac 0} {dcmac_axil 0} {board v80} } {

  variable script_folder

  if { $parentCell eq "" || $nameHier eq "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2092 -severity "ERROR" "create_hier_cell_dcmac_wrapper() - Empty argument(s)!"}
     return
  }
  if {![string is integer -strict $dcmac_axil] || !($dcmac_axil == 0 || $dcmac_axil == 1)} {
     catch {common::send_gid_msg -ssname BD::TCL -id 2092 -severity "ERROR" \
        "create_hier_cell_dcmac_wrapper() - dcmac_axil (value: $dcmac_axil) must be 0 or 1"}
     return
  }

  # Get object for parentCell
  set parentObj [get_bd_cells $parentCell]
  if { $parentObj == "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2090 -severity "ERROR" "Unable to find parent cell <$parentCell>!"}
     return
  }

  # Make sure parentObj is hier blk
  set parentType [get_property TYPE $parentObj]
  if { $parentType ne "hier" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2091 -severity "ERROR" "Parent <$parentObj> has TYPE = <$parentType>. Expected to be <hier>."}
     return
  }

  # Save current instance; Restore later
  set oldCurInst [current_bd_instance .]

  # Set parent object as current
  current_bd_instance $parentObj

  # Create cell and set as current instance
  set hier_obj [create_bd_cell -type hier $nameHier]
  current_bd_instance $hier_obj

  # Create interface pins (QSFP 0 — always present)
  create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:axis_rtl:1.0 M_AXIS_0
  create_bd_intf_pin -mode Slave  -vlnv xilinx.com:interface:axis_rtl:1.0 S_AXIS_0

  # QSFP 1 — only when dual_dcmac is enabled.
  if { ${dual_dcmac} == "1" } {
    create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:axis_rtl:1.0 M_AXIS_1
    create_bd_intf_pin -mode Slave  -vlnv xilinx.com:interface:axis_rtl:1.0 S_AXIS_1
  }

  # Create pins
  create_bd_pin -dir O -from 255 -to 0 tx_data_0
  create_bd_pin -dir O -from 255 -to 0 tx_data_1
  create_bd_pin -dir O -from 255 -to 0 tx_data_2
  create_bd_pin -dir O -from 255 -to 0 tx_data_3
  create_bd_pin -dir I -from 255 -to 0 rx_data_0
  create_bd_pin -dir I -from 255 -to 0 rx_data_1
  create_bd_pin -dir I -from 255 -to 0 rx_data_2
  create_bd_pin -dir I -from 255 -to 0 rx_data_3

  # GT-side data buses for lanes 4-7 — only when dual_dcmac is enabled.
  # These connect to the DCMAC IP's txdata_out_4..7 / rxdata_in_4..7 below.
  if { ${dual_dcmac} == "1" } {
    create_bd_pin -dir O -from 255 -to 0 tx_data_4
    create_bd_pin -dir O -from 255 -to 0 tx_data_5
    create_bd_pin -dir O -from 255 -to 0 tx_data_6
    create_bd_pin -dir O -from 255 -to 0 tx_data_7
    create_bd_pin -dir I -from 255 -to 0 rx_data_4
    create_bd_pin -dir I -from 255 -to 0 rx_data_5
    create_bd_pin -dir I -from 255 -to 0 rx_data_6
    create_bd_pin -dir I -from 255 -to 0 rx_data_7
  }
  create_bd_pin -dir I tx_clk
  create_bd_pin -dir I -type gt_usrclk tx_clk_alt
  create_bd_pin -dir I -type gt_usrclk rx_clk
  create_bd_pin -dir I rx_clk_alt
  create_bd_pin -dir I -type clk core_clk
  set axis_clk_pin [create_bd_pin -dir I -type clk axis_clk]
  create_bd_pin -dir I -type rst axis_tx_resetn
  create_bd_pin -dir I -type rst axis_rx_resetn

  # Self-describing clock/reset associations on axis_clk. 390998840 is the EXACT
  # DCMAC AXIS clock; do NOT replace with nclk_f * 1e6 (see dcmac.tcl:580).
  set axis_busif "S_AXIS_0:M_AXIS_0"
  if { ${dual_dcmac} == "1" } {
    append axis_busif ":S_AXIS_1:M_AXIS_1"
  }
  set_property -dict [list \
    CONFIG.FREQ_HZ {390998840} \
    CONFIG.ASSOCIATED_BUSIF $axis_busif \
    CONFIG.ASSOCIATED_RESET {axis_tx_resetn:axis_rx_resetn} \
  ] $axis_clk_pin
  create_bd_pin -dir I -type rst tx_core_reset
  create_bd_pin -dir I -from 5 -to 0 tx_channel_flush
  create_bd_pin -dir I -from 5 -to 0 -type rst tx_serdes_reset
  create_bd_pin -dir I -type rst rx_core_reset
  create_bd_pin -dir I -from 5 -to 0 -type rst rx_serdes_reset
  create_bd_pin -dir I -from 5 -to 0 rx_channel_flush
  create_bd_pin -dir I -type clk ts_axil_clk

  # AXI4-Lite slave to the DCMAC IP — exposed only when enabled
  if { ${dcmac_axil} == "1" } {
    create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 s_axi
    create_bd_pin -dir I -type clk s_axi_aclk
    create_bd_pin -dir I -type rst s_axi_aresetn
  }

  # Select DCMAC location from the per-board dict (board_config.tcl).
  if { ![dict exists $::_dcmac_board_loc $board $dcmac_index] } {
    catch {common::send_gid_msg -ssname BD::TCL -id 2092 -severity "ERROR" \
       "create_hier_cell_dcmac_wrapper() - no DCMAC site for board=$board, dcmac_index=$dcmac_index. \
        Known boards: [dict keys $::_dcmac_board_loc]"}
    return
  }
  set dcmac_loc [dict get $::_dcmac_board_loc $board $dcmac_index]

  # Create instance: dcmac, and set properties
  set dcmac_name "dcmac_${dcmac_index}"
  set dcmac [ create_bd_cell -type ip -vlnv xilinx.com:ip:dcmac $dcmac_name ]
  set_property -dict [list \
    CONFIG.DCMAC_LOCATION_C0 $dcmac_loc \
    CONFIG.GT_REF_CLK_FREQ_C0 $::dcmac_gt_refclk_mhz \
    CONFIG.IS_GT_WIZ_OLD {0} \
    CONFIG.MAC_PORT0_CONFIG_C0 {200GAUI-4} \
    CONFIG.MAC_PORT0_RX_STRIP_C0 {1} \
    CONFIG.MAC_PORT1_RX_STRIP_C0 {1} \
    CONFIG.MAC_PORT2_ENABLE_C0 {0} \
    CONFIG.MAC_PORT3_ENABLE_C0 {0} \
    CONFIG.MAC_PORT4_ENABLE_C0 {0} \
    CONFIG.MAC_PORT5_ENABLE_C0 {0} \
    CONFIG.USE_AXIS_ALMOSTFULL_INDICATION {0} \
  ] $dcmac

  # Enable additional ports for dual QSFP
  if { ${dual_dcmac} == "1" } {
    set_property -dict [list \
      CONFIG.MAC_PORT2_ENABLE_C0 {1} \
      CONFIG.MAC_PORT2_RX_STRIP_C0 {1} \
      CONFIG.MAC_PORT3_ENABLE_C0 {1} \
      CONFIG.MAC_PORT3_RX_STRIP_C0 {1} \
    ] $dcmac
  }

  # Create instance: dcmac200g_ctl_port, and set properties
  set block_name dcmac200g_ctl_port
  set block_cell_name dcmac200g_ctl_port
  if { [catch {set dcmac200g_ctl_port [create_bd_cell -type module -reference $block_name $block_cell_name] } errmsg] } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2095 -severity "ERROR" "Unable to add referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   } elseif { $dcmac200g_ctl_port eq "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2096 -severity "ERROR" "Unable to referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   }

  # Create instance: seg_to_axis_0 (QSFP 0 RX seg -> AXIS), and set properties
  set block_name axis_seg_to_unseg_converter
  set block_cell_name seg_to_axis_0
  if { [catch {set seg_to_axis_0 [create_bd_cell -type module -reference $block_name $block_cell_name] } errmsg] } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2095 -severity "ERROR" "Unable to add referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   } elseif { $seg_to_axis_0 eq "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2096 -severity "ERROR" "Unable to referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   }

  # Magic number: the actual DCMAC AXIS clock derived from the 322.265625 MHz
  set_property -dict [list \
    CONFIG.FREQ_HZ {390998840} \
  ] [get_bd_intf_pins seg_to_axis_0/m_axis0_pkt_out]

  # Create instance: seg_to_axis_1 (QSFP 1 RX seg -> AXIS), only when dual_dcmac
  if { ${dual_dcmac} == "1" } {
    set block_cell_name seg_to_axis_1
    if { [catch {set seg_to_axis_1 [create_bd_cell -type module -reference $block_name $block_cell_name] } errmsg] } {
       catch {common::send_gid_msg -ssname BD::TCL -id 2095 -severity "ERROR" "Unable to add referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
       return 1
     } elseif { $seg_to_axis_1 eq "" } {
       catch {common::send_gid_msg -ssname BD::TCL -id 2096 -severity "ERROR" "Unable to referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
       return 1
     }
    set_property -dict [list \
      CONFIG.FREQ_HZ {390998840} \
    ] [get_bd_intf_pins seg_to_axis_1/m_axis0_pkt_out]
  }

  # Create instance: const_0, and set properties
  set const_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_0 ]
  set_property CONFIG.CONST_VAL {0} $const_0

  # Create instance: flexif_clk_tx, and set properties
  set block_name clk_to_flexif_clk
  set block_cell_name flexif_clk_tx
  if { [catch {set flexif_clk_tx [create_bd_cell -type module -reference $block_name $block_cell_name] } errmsg] } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2095 -severity "ERROR" "Unable to add referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   } elseif { $flexif_clk_tx eq "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2096 -severity "ERROR" "Unable to referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   }

  # Create instance: alt_serdes_clk_tx, and set properties
  set block_name clk_to_alt_serdes_clk
  set block_cell_name alt_serdes_clk_tx
  if { [catch {set alt_serdes_clk_tx [create_bd_cell -type module -reference $block_name $block_cell_name] } errmsg] } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2095 -severity "ERROR" "Unable to add referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   } elseif { $alt_serdes_clk_tx eq "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2096 -severity "ERROR" "Unable to referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   }

  # Create instance: serdes_clk_tx, and set properties
  set block_name clk_to_serdes_clk
  set block_cell_name serdes_clk_tx
  if { [catch {set serdes_clk_tx [create_bd_cell -type module -reference $block_name $block_cell_name] } errmsg] } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2095 -severity "ERROR" "Unable to add referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   } elseif { $serdes_clk_tx eq "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2096 -severity "ERROR" "Unable to referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   }

  # Create instance: flexif_clk_rx, and set properties
  set block_name clk_to_flexif_clk
  set block_cell_name flexif_clk_rx
  if { [catch {set flexif_clk_rx [create_bd_cell -type module -reference $block_name $block_cell_name] } errmsg] } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2095 -severity "ERROR" "Unable to add referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   } elseif { $flexif_clk_rx eq "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2096 -severity "ERROR" "Unable to referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   }

  # Create instance: alt_serdes_clk_rx, and set properties
  set block_name clk_to_alt_serdes_clk
  set block_cell_name alt_serdes_clk_rx
  if { [catch {set alt_serdes_clk_rx [create_bd_cell -type module -reference $block_name $block_cell_name] } errmsg] } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2095 -severity "ERROR" "Unable to add referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   } elseif { $alt_serdes_clk_rx eq "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2096 -severity "ERROR" "Unable to referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   }

  # Create instance: ts_clk, and set properties
  set block_name clk_to_ts_clk
  set block_cell_name ts_clk
  if { [catch {set ts_clk [create_bd_cell -type module -reference $block_name $block_cell_name] } errmsg] } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2095 -severity "ERROR" "Unable to add referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   } elseif { $ts_clk eq "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2096 -severity "ERROR" "Unable to referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   }

  # Create instance: serdes_clk_rx, and set properties
  set block_name clk_to_serdes_clk
  set block_cell_name serdes_clk_rx
  if { [catch {set serdes_clk_rx [create_bd_cell -type module -reference $block_name $block_cell_name] } errmsg] } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2095 -severity "ERROR" "Unable to add referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   } elseif { $serdes_clk_rx eq "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2096 -severity "ERROR" "Unable to referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   }

  # Create instance: axis_to_seg_0 (QSFP 0 TX AXIS -> seg), and set properties
  set block_name axis_to_dcmac_seg_wrapper
  set block_cell_name axis_to_seg_0
  if { [catch {set axis_to_seg_0 [create_bd_cell -type module -reference $block_name $block_cell_name] } errmsg] } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2095 -severity "ERROR" "Unable to add referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   } elseif { $axis_to_seg_0 eq "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2096 -severity "ERROR" "Unable to referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   }

  # Create instance: axis_to_seg_1 (QSFP 1 TX AXIS -> seg), only when dual_dcmac
  if { ${dual_dcmac} == "1" } {
    set block_cell_name axis_to_seg_1
    if { [catch {set axis_to_seg_1 [create_bd_cell -type module -reference $block_name $block_cell_name] } errmsg] } {
       catch {common::send_gid_msg -ssname BD::TCL -id 2095 -severity "ERROR" "Unable to add referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
       return 1
     } elseif { $axis_to_seg_1 eq "" } {
       catch {common::send_gid_msg -ssname BD::TCL -id 2096 -severity "ERROR" "Unable to referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
       return 1
     }
  }

  # Create instance: const_1, and set properties.
  # Only needed when AXI4-Lite is tied off — otherwise s_axi_bready/rready/aresetn come from the real AXI master and reset.
  if { ${dcmac_axil} == "0" } {
    set const_1 [ create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_1 ]
  }

  # Create interface connections (QSFP 0)
  connect_bd_intf_net -intf_net S_AXIS_0_net [get_bd_intf_pins S_AXIS_0] [get_bd_intf_pins axis_to_seg_0/s_axis]
  connect_bd_intf_net -intf_net seg_to_axis_m_axis0_pkt_out [get_bd_intf_pins M_AXIS_0] [get_bd_intf_pins seg_to_axis_0/m_axis0_pkt_out]

  # Create port connections
  connect_bd_net -net alt_serdes_clk_rx_serdes_clk  [get_bd_pins alt_serdes_clk_rx/serdes_clk] [get_bd_pins $dcmac_name/rx_alt_serdes_clk]
  connect_bd_net -net alt_serdes_clk_tx_serdes_clk  [get_bd_pins alt_serdes_clk_tx/serdes_clk] [get_bd_pins $dcmac_name/tx_alt_serdes_clk]
  connect_bd_net -net aresetn_axis_seg_in_2  [get_bd_pins axis_rx_resetn] [get_bd_pins seg_to_axis_0/aresetn_axis_seg_in]

  # TX seg buses (QSFP 0, lanes 0-3): axis_to_seg_0 -> dcmac IP.
  # `data` maps to dcmac pin `tx_axis_tdata${lane}`; the other fields map to
  # `tx_axis_tuser_<field>${lane}`.
  foreach {field dcmac_field} {data tdata ena tuser_ena eop tuser_eop err tuser_err mty tuser_mty sop tuser_sop} {
    for {set lane 0} {$lane <= 3} {incr lane} {
      connect_bd_net -net axis_to_dcmac_seg_tx_${field}_${lane} \
        [get_bd_pins axis_to_seg_0/tx_${field}_${lane}] \
        [get_bd_pins $dcmac_name/tx_axis_${dcmac_field}${lane}]
    }
  }
  connect_bd_net -net axis_to_dcmac_seg_tx_valid  [get_bd_pins axis_to_seg_0/tx_valid] [get_bd_pins $dcmac_name/tx_axis_tvalid_0]
  connect_bd_net -net axis_tx_resetn_1  [get_bd_pins axis_tx_resetn] [get_bd_pins axis_to_seg_0/aresetn]
  if { ${dcmac_axil} == "1" } {
    # Real AXI master drives s_axi; const_0 only feeds the pm_tick pins.
    connect_bd_net -net const_0_dout  [get_bd_pins const_0/dout] \
      [get_bd_pins $dcmac_name/rx_all_channel_mac_pm_tick] \
      [get_bd_pins $dcmac_name/rx_port_pm_tick] \
      [get_bd_pins $dcmac_name/tx_all_channel_mac_pm_tick] \
      [get_bd_pins $dcmac_name/tx_port_pm_tick]
    connect_bd_intf_net [get_bd_intf_pins s_axi] [get_bd_intf_pins $dcmac_name/s_axi]
    connect_bd_net [get_bd_pins s_axi_aresetn] [get_bd_pins $dcmac_name/s_axi_aresetn]
  } else {
    # AXI4-Lite tied off (Coyote default).
    connect_bd_net -net const_0_dout  [get_bd_pins const_0/dout] \
      [get_bd_pins $dcmac_name/rx_all_channel_mac_pm_tick] \
      [get_bd_pins $dcmac_name/rx_port_pm_tick] \
      [get_bd_pins $dcmac_name/tx_all_channel_mac_pm_tick] \
      [get_bd_pins $dcmac_name/tx_port_pm_tick] \
      [get_bd_pins $dcmac_name/s_axi_arvalid] \
      [get_bd_pins $dcmac_name/s_axi_awvalid] \
      [get_bd_pins $dcmac_name/s_axi_wvalid]
    connect_bd_net -net const_1_dout  [get_bd_pins const_1/dout] \
      [get_bd_pins $dcmac_name/s_axi_bready] \
      [get_bd_pins $dcmac_name/s_axi_rready] \
      [get_bd_pins $dcmac_name/s_axi_aresetn]
  }
  # 200G VL marker IDs 0-19: dcmac200g_ctl_port -> dcmac IP.
  for {set id 0} {$id <= 19} {incr id} {
    connect_bd_net -net dcmac200g_ctl_port_ctl_tx_vl_marker_id${id} \
      [get_bd_pins dcmac200g_ctl_port/ctl_tx_vl_marker_id${id}] \
      [get_bd_pins $dcmac_name/ctl_vl_marker_id${id}]
  }
  connect_bd_net -net dcmac200g_ctl_port_default_vl_length_200GE_or_400GE  [get_bd_pins dcmac200g_ctl_port/default_vl_length_200GE_or_400GE] \
    [get_bd_pins $dcmac_name/ctl_rx_custom_vl_length_minus1] \
    [get_bd_pins $dcmac_name/ctl_tx_custom_vl_length_minus1]

  # RX seg buses (QSFP 0, lanes 0-3): dcmac IP -> seg_to_axis_0.
  # `tdata` maps to `Seg2UnSegDat${lane}_in`; the others map to
  # `Seg2UnSeg<Field>${lane}_in` (capitalized field).
  foreach {dcmac_field seg_field} {tdata Dat tuser_ena Ena tuser_eop Eop tuser_err Err tuser_mty Mty tuser_sop Sop} {
    for {set lane 0} {$lane <= 3} {incr lane} {
      connect_bd_net -net dcmac_rx_axis_${dcmac_field}${lane} \
        [get_bd_pins $dcmac_name/rx_axis_${dcmac_field}${lane}] \
        [get_bd_pins seg_to_axis_0/Seg2UnSeg${seg_field}${lane}_in]
    }
  }
  connect_bd_net -net dcmac_rx_axis_tvalid_0  [get_bd_pins $dcmac_name/rx_axis_tvalid_0] [get_bd_pins seg_to_axis_0/rx_axis_tvalid_i]
  connect_bd_net -net dcmac_tx_axis_tready_0  [get_bd_pins $dcmac_name/tx_axis_tready_0] [get_bd_pins axis_to_seg_0/tx_ready]

  # GT TX/RX data lanes 0-3: dcmac IP <-> hier pins (paired with the rxdata_in loop further below)
  for {set lane 0} {$lane <= 3} {incr lane} {
    connect_bd_net -net dcmac_txdata_out_${lane} \
      [get_bd_pins $dcmac_name/txdata_out_${lane}] \
      [get_bd_pins tx_data_${lane}]
  }
  connect_bd_net -net flexif_clk_rx_flexif_clk  [get_bd_pins flexif_clk_rx/flexif_clk] [get_bd_pins $dcmac_name/rx_flexif_clk]
  connect_bd_net -net flexif_clk_tx_flexif_clk  [get_bd_pins flexif_clk_tx/flexif_clk] [get_bd_pins $dcmac_name/tx_flexif_clk]
  connect_bd_net -net rx_axi_clk_1  [get_bd_pins axis_clk] \
    [get_bd_pins $dcmac_name/rx_axi_clk] \
    [get_bd_pins $dcmac_name/rx_macif_clk] \
    [get_bd_pins $dcmac_name/tx_axi_clk] \
    [get_bd_pins $dcmac_name/tx_macif_clk] \
    [get_bd_pins seg_to_axis_0/aclk_axis_seg_in] \
    [get_bd_pins flexif_clk_rx/clk] \
    [get_bd_pins flexif_clk_tx/clk] \
    [get_bd_pins axis_to_seg_0/aclk]
  connect_bd_net -net rx_channel_flush_1  [get_bd_pins rx_channel_flush] [get_bd_pins $dcmac_name/rx_channel_flush]
  connect_bd_net -net rx_clk_1  [get_bd_pins rx_clk] [get_bd_pins serdes_clk_rx/clk]
  connect_bd_net -net rx_clk_alt_1  [get_bd_pins rx_clk_alt] [get_bd_pins alt_serdes_clk_rx/clk]
  connect_bd_net -net rx_core_clk_1  [get_bd_pins core_clk] \
    [get_bd_pins $dcmac_name/rx_core_clk] \
    [get_bd_pins $dcmac_name/tx_core_clk]
  connect_bd_net -net rx_core_reset_1  [get_bd_pins rx_core_reset] [get_bd_pins $dcmac_name/rx_core_reset]
  connect_bd_net -net rx_serdes_reset_1  [get_bd_pins rx_serdes_reset]  [get_bd_pins $dcmac_name/rx_serdes_reset]
  for {set lane 0} {$lane <= 3} {incr lane} {
    connect_bd_net -net rxdata_in_${lane}_1 \
      [get_bd_pins rx_data_${lane}] \
      [get_bd_pins $dcmac_name/rxdata_in_${lane}]
  }
  connect_bd_net -net serdes_clk_rx_serdes_clk  [get_bd_pins serdes_clk_rx/serdes_clk] [get_bd_pins $dcmac_name/rx_serdes_clk]
  connect_bd_net -net serdes_clk_tx_serdes_clk  [get_bd_pins serdes_clk_tx/serdes_clk] [get_bd_pins $dcmac_name/tx_serdes_clk]

  if { ${dcmac_axil} == "1" } {
    # AXI4-Lite shares the user aclk/aresetn domain. ts_axil_clk feeds only the
    # ts_clk generator; the DCMAC's s_axi_aclk is driven by the wrapper's
    # s_axi_aclk hier pin (which the top level ties to aclk).
    connect_bd_net -net ts_clk_1 [get_bd_pins ts_axil_clk] [get_bd_pins ts_clk/clk]
    connect_bd_net [get_bd_pins s_axi_aclk] [get_bd_pins $dcmac_name/s_axi_aclk]
  } else {
    connect_bd_net -net ts_clk_1  [get_bd_pins ts_axil_clk] \
      [get_bd_pins ts_clk/clk] \
      [get_bd_pins $dcmac_name/s_axi_aclk]
  }
  connect_bd_net -net ts_clk_ts_clk  [get_bd_pins ts_clk/ts_clk] [get_bd_pins $dcmac_name/ts_clk]
  connect_bd_net -net tx_channel_flush_1  [get_bd_pins tx_channel_flush] [get_bd_pins $dcmac_name/tx_channel_flush]
  connect_bd_net -net tx_clk_1  [get_bd_pins tx_clk] [get_bd_pins serdes_clk_tx/clk]
  connect_bd_net -net tx_clk_alt_1  [get_bd_pins tx_clk_alt] [get_bd_pins alt_serdes_clk_tx/clk]
  connect_bd_net -net tx_core_reset_1  [get_bd_pins tx_core_reset] [get_bd_pins $dcmac_name/tx_core_reset]
  connect_bd_net -net tx_serdes_reset_1  [get_bd_pins tx_serdes_reset] [get_bd_pins $dcmac_name/tx_serdes_reset]

  # ---------------------------------------------------------------------------
  # Dual-QSFP wiring: connect axis_to_seg_1 / seg_to_axis_1 to the dcmac IP
  # (lanes 4-7, AXIS port index 2 -> MAC ports 2/3) and to the S_AXIS_1 /
  # M_AXIS_1 hierarchy interface pins. SLASH uses the same lane mapping
  # ---------------------------------------------------------------------------
  if { ${dual_dcmac} == "1" } {
    # AXIS interface pins to/from the converters
    connect_bd_intf_net [get_bd_intf_pins S_AXIS_1]  [get_bd_intf_pins axis_to_seg_1/s_axis]
    connect_bd_intf_net [get_bd_intf_pins M_AXIS_1]  [get_bd_intf_pins seg_to_axis_1/m_axis0_pkt_out]
    set_property -dict [list CONFIG.FREQ_HZ {390998840}] [get_bd_intf_pins seg_to_axis_1/m_axis0_pkt_out]

    # Clocks / resets (shared with QSFP 0)
    connect_bd_net [get_bd_pins axis_clk]       [get_bd_pins axis_to_seg_1/aclk] \
                                                [get_bd_pins seg_to_axis_1/aclk_axis_seg_in]
    connect_bd_net [get_bd_pins axis_tx_resetn] [get_bd_pins axis_to_seg_1/aresetn]
    connect_bd_net [get_bd_pins axis_rx_resetn] [get_bd_pins seg_to_axis_1/aresetn_axis_seg_in]

    # TX seg buses (lanes 4-7) to dcmac IP
    for {set lane 0} {$lane <= 3} {incr lane} {
      set dcmac_lane [expr {$lane + 4}]
      connect_bd_net [get_bd_pins axis_to_seg_1/tx_data_${lane}] [get_bd_pins $dcmac_name/tx_axis_tdata${dcmac_lane}]
      connect_bd_net [get_bd_pins axis_to_seg_1/tx_ena_${lane}]  [get_bd_pins $dcmac_name/tx_axis_tuser_ena${dcmac_lane}]
      connect_bd_net [get_bd_pins axis_to_seg_1/tx_eop_${lane}]  [get_bd_pins $dcmac_name/tx_axis_tuser_eop${dcmac_lane}]
      connect_bd_net [get_bd_pins axis_to_seg_1/tx_err_${lane}]  [get_bd_pins $dcmac_name/tx_axis_tuser_err${dcmac_lane}]
      connect_bd_net [get_bd_pins axis_to_seg_1/tx_mty_${lane}]  [get_bd_pins $dcmac_name/tx_axis_tuser_mty${dcmac_lane}]
      connect_bd_net [get_bd_pins axis_to_seg_1/tx_sop_${lane}]  [get_bd_pins $dcmac_name/tx_axis_tuser_sop${dcmac_lane}]

      connect_bd_net [get_bd_pins $dcmac_name/rx_axis_tdata${dcmac_lane}]      [get_bd_pins seg_to_axis_1/Seg2UnSegDat${lane}_in]
      connect_bd_net [get_bd_pins $dcmac_name/rx_axis_tuser_ena${dcmac_lane}]  [get_bd_pins seg_to_axis_1/Seg2UnSegEna${lane}_in]
      connect_bd_net [get_bd_pins $dcmac_name/rx_axis_tuser_eop${dcmac_lane}]  [get_bd_pins seg_to_axis_1/Seg2UnSegEop${lane}_in]
      connect_bd_net [get_bd_pins $dcmac_name/rx_axis_tuser_err${dcmac_lane}]  [get_bd_pins seg_to_axis_1/Seg2UnSegErr${lane}_in]
      connect_bd_net [get_bd_pins $dcmac_name/rx_axis_tuser_mty${dcmac_lane}]  [get_bd_pins seg_to_axis_1/Seg2UnSegMty${lane}_in]
      connect_bd_net [get_bd_pins $dcmac_name/rx_axis_tuser_sop${dcmac_lane}]  [get_bd_pins seg_to_axis_1/Seg2UnSegSop${lane}_in]
    }

    # Per-port valid/ready (AXIS port index 2)
    connect_bd_net [get_bd_pins axis_to_seg_1/tx_valid]         [get_bd_pins $dcmac_name/tx_axis_tvalid_2]
    connect_bd_net [get_bd_pins $dcmac_name/tx_axis_tready_2]   [get_bd_pins axis_to_seg_1/tx_ready]
    connect_bd_net [get_bd_pins $dcmac_name/rx_axis_tvalid_2]   [get_bd_pins seg_to_axis_1/rx_axis_tvalid_i]

    # GT TX/RX data lanes 4-7: dcmac IP <-> hier boundary pins (mirrors the
    # lanes-0-3 loops above; consumed by gt_wrapper's gtwiz_versal_1 cell).
    for {set lane 4} {$lane <= 7} {incr lane} {
      connect_bd_net -net dcmac_txdata_out_${lane} \
        [get_bd_pins $dcmac_name/txdata_out_${lane}] \
        [get_bd_pins tx_data_${lane}]
      connect_bd_net -net rxdata_in_${lane}_1 \
        [get_bd_pins rx_data_${lane}] \
        [get_bd_pins $dcmac_name/rxdata_in_${lane}]
    }
  }

  # Restore current instance
  current_bd_instance $oldCurInst
}

# Hierarchical cell: gt_wrapper
proc create_hier_cell_gt_wrapper { parentCell nameHier {dual_dcmac 0} } {

  variable script_folder

  if { $parentCell eq "" || $nameHier eq "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2092 -severity "ERROR" "create_hier_cell_gt_wrapper() - Empty argument(s)!"}
     return
  }

  if {![string is integer -strict $dual_dcmac] || !($dual_dcmac == 0 || $dual_dcmac == 1)} {
     catch {common::send_gid_msg -ssname BD::TCL -id 2092 -severity "ERROR" "create_hier_cell_gt_wrapper(): dual_dcmac (value: $dual_dcmac) must be 0 or 1"}
     return
  }

  # Get object for parentCell
  set parentObj [get_bd_cells $parentCell]
  if { $parentObj == "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2090 -severity "ERROR" "Unable to find parent cell <$parentCell>!"}
     return
  }

  # Make sure parentObj is hier blk
  set parentType [get_property TYPE $parentObj]
  if { $parentType ne "hier" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2091 -severity "ERROR" "Parent <$parentObj> has TYPE = <$parentType>. Expected to be <hier>."}
     return
  }

  # Save current instance; Restore later
  set oldCurInst [current_bd_instance .]

  # Set parent object as current
  current_bd_instance $parentObj

  # Create cell and set as current instance
  set hier_obj [create_bd_cell -type hier $nameHier]
  current_bd_instance $hier_obj

  # Create interface pins
  create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:gt_rtl:1.0 qsfp_gt0

  # Create pins
  create_bd_pin -dir O gt_rst_rx_done
  create_bd_pin -dir O gt_rst_tx_done
  create_bd_pin -dir I gt_rst
  create_bd_pin -dir I -type clk gt_ref_clk
  create_bd_pin -dir I -from 255 -to 0 tx_data_0
  create_bd_pin -dir I -from 255 -to 0 tx_data_1
  create_bd_pin -dir I -from 255 -to 0 tx_data_2
  create_bd_pin -dir I -from 255 -to 0 tx_data_3
  create_bd_pin -dir O -from 255 -to 0 rx_data_0
  create_bd_pin -dir O -from 255 -to 0 rx_data_1
  create_bd_pin -dir O -from 255 -to 0 rx_data_2
  create_bd_pin -dir O -from 255 -to 0 rx_data_3
  create_bd_pin -dir O -from 0 -to 0 -type gt_usrclk tx_clk
  create_bd_pin -dir O -from 0 -to 0 -type gt_usrclk rx_clk_alt
  create_bd_pin -dir O -from 0 -to 0 -type gt_usrclk tx_clk_alt
  create_bd_pin -dir O -from 0 -to 0 -type gt_usrclk rx_clk
  create_bd_pin -dir I -type clk gtwiz_freerun_clk

  # Create instance: gtwiz_versal_0, and set properties
  set gtwiz_versal_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:gtwiz_versal:1.0 gtwiz_versal_0 ]
  set_property -dict [list \
    CONFIG.GT_TYPE {GTM} \
    CONFIG.INTF0_GT_SETTINGS(LR0_SETTINGS) "RXPROGDIV_FREQ_VAL 664.062 RX_REFCLK_FREQUENCY $::dcmac_gt_refclk_mhz TXPROGDIV_FREQ_VAL 664.062 TX_REFCLK_FREQUENCY $::dcmac_gt_refclk_mhz" \
    CONFIG.INTF0_NO_OF_LANES {4} \
    CONFIG.INTF0_PARENTID {undef} \
    CONFIG.INTF0_PRESET {GTM-PAM4_Ethernet_53G} \
    CONFIG.INTF_PARENT_PIN_LIST {QUAD0_RX0 {{}} QUAD0_RX1 {{}} QUAD0_RX2 {{}} QUAD0_RX3 {{}} QUAD0_TX0 {{}} QUAD0_TX1 {{}} QUAD0_TX2 {{}} QUAD0_TX3 {{}}} \
    CONFIG.NO_OF_QUADS {1} \
    CONFIG.QUAD0_CH0_LOOPBACK_EN {true} \
    CONFIG.QUAD0_CH1_LOOPBACK_EN {true} \
    CONFIG.QUAD0_CH2_LOOPBACK_EN {true} \
    CONFIG.QUAD0_CH3_LOOPBACK_EN {true} \
    CONFIG.QUAD0_GT_GPIO_EN {false} \
    CONFIG.QUAD0_REFCLK_STRING {HSCLK0_LCPLLGTREFCLK0 refclk_PROT0_R0_322.265625183611_MHz_unique1} \
  ] $gtwiz_versal_0

  set_property -dict [list \
    CONFIG.INTF0_PARENTID.VALUE_MODE {auto} \
    CONFIG.INTF_PARENT_PIN_LIST.VALUE_MODE {auto} \
  ] $gtwiz_versal_0

  # Create instance: mbufg_rx, and set properties
  set mbufg_rx [ create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf:2.2 mbufg_rx ]
  set_property CONFIG.C_BUF_TYPE {MBUFG_GT} $mbufg_rx

  # Create instance: mbufg_tx, and set properties
  set mbufg_tx [ create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf:2.2 mbufg_tx ]
  set_property CONFIG.C_BUF_TYPE {MBUFG_GT} $mbufg_tx

  # Create instance: const_1, and set properties
  set const_1 [ create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_1 ]

  # Create instance: const_0, and set properties
  set const_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_0 ]
  set_property CONFIG.CONST_VAL {0} $const_0

  # Create instance: const_tx_main_cursor, and set properties
  set const_tx_main_cursor [ create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_tx_main_cursor ]
  set_property -dict [list \
    CONFIG.CONST_VAL {52} \
    CONFIG.CONST_WIDTH {7} \
  ] $const_tx_main_cursor

  # Create instance: const_tx_pre_post_cursor, and set properties
  set const_tx_pre_post_cursor [ create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_tx_pre_post_cursor ]
  set_property -dict [list \
    CONFIG.CONST_VAL {6} \
    CONFIG.CONST_WIDTH {6} \
  ] $const_tx_pre_post_cursor

  # Create instance: const_loopback, and set properties
  set const_loopback [ create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_loopback ]
  set_property -dict [list \
    CONFIG.CONST_VAL {0} \
    CONFIG.CONST_WIDTH {3} \
  ] $const_loopback

  # Create instance: const_gt_rate, and set properties
  set const_gt_rate [ create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_gt_rate ]
  set_property -dict [list \
    CONFIG.CONST_VAL {0} \
    CONFIG.CONST_WIDTH {8} \
  ] $const_gt_rate

  # Create interface connections
  connect_bd_intf_net -intf_net Conn1 [get_bd_intf_pins gtwiz_versal_0/Quad0_GT_Serial] [get_bd_intf_pins qsfp_gt0]

  # Create port connections
  connect_bd_net -net INTF0_TX0_ch_txdata_1  [get_bd_pins tx_data_0] [get_bd_pins gtwiz_versal_0/INTF0_TX0_ch_txdata]
  connect_bd_net -net INTF0_TX1_ch_txdata_1  [get_bd_pins tx_data_1] [get_bd_pins gtwiz_versal_0/INTF0_TX1_ch_txdata]
  connect_bd_net -net INTF0_TX2_ch_txdata_1  [get_bd_pins tx_data_2] [get_bd_pins gtwiz_versal_0/INTF0_TX2_ch_txdata]
  connect_bd_net -net INTF0_TX3_ch_txdata_1  [get_bd_pins tx_data_3] [get_bd_pins gtwiz_versal_0/INTF0_TX3_ch_txdata]
  connect_bd_net -net MBUFG_GT_CE_1  [get_bd_pins const_1/dout] \
    [get_bd_pins mbufg_rx/MBUFG_GT_CE] \
    [get_bd_pins mbufg_tx/MBUFG_GT_CE]
  connect_bd_net -net QUAD0_GTREFCLK0_1  [get_bd_pins gt_ref_clk] [get_bd_pins gtwiz_versal_0/QUAD0_GTREFCLK0]
  connect_bd_net -net const_0_dout  [get_bd_pins const_0/dout] \
    [get_bd_pins gtwiz_versal_0/INTF0_rst_rx_pll_and_datapath_in] \
    [get_bd_pins gtwiz_versal_0/INTF0_rst_tx_datapath_in] \
    [get_bd_pins gtwiz_versal_0/INTF0_rst_tx_pll_and_datapath_in] \
    [get_bd_pins gtwiz_versal_0/INTF0_rst_rx_datapath_in] \
    [get_bd_pins gtwiz_versal_0/INTF0_RX0_ch_rxcdrhold] \
    [get_bd_pins gtwiz_versal_0/INTF0_RX1_ch_rxcdrhold] \
    [get_bd_pins gtwiz_versal_0/INTF0_RX2_ch_rxcdrhold] \
    [get_bd_pins gtwiz_versal_0/INTF0_RX3_ch_rxcdrhold]
  connect_bd_net -net const_gt_rate_dout  [get_bd_pins const_gt_rate/dout] \
    [get_bd_pins gtwiz_versal_0/INTF0_RX0_ch_rxrate] \
    [get_bd_pins gtwiz_versal_0/INTF0_RX1_ch_rxrate] \
    [get_bd_pins gtwiz_versal_0/INTF0_RX2_ch_rxrate] \
    [get_bd_pins gtwiz_versal_0/INTF0_RX3_ch_rxrate] \
    [get_bd_pins gtwiz_versal_0/INTF0_TX0_ch_txrate] \
    [get_bd_pins gtwiz_versal_0/INTF0_TX1_ch_txrate] \
    [get_bd_pins gtwiz_versal_0/INTF0_TX2_ch_txrate] \
    [get_bd_pins gtwiz_versal_0/INTF0_TX3_ch_txrate]
  connect_bd_net -net const_loopback_dout  [get_bd_pins const_loopback/dout] \
    [get_bd_pins gtwiz_versal_0/QUAD0_ch0_loopback] \
    [get_bd_pins gtwiz_versal_0/QUAD0_ch1_loopback] \
    [get_bd_pins gtwiz_versal_0/QUAD0_ch2_loopback] \
    [get_bd_pins gtwiz_versal_0/QUAD0_ch3_loopback]
  connect_bd_net -net const_tx_main_cursor_dout  [get_bd_pins const_tx_main_cursor/dout] \
    [get_bd_pins gtwiz_versal_0/INTF0_TX0_ch_txmaincursor] \
    [get_bd_pins gtwiz_versal_0/INTF0_TX1_ch_txmaincursor] \
    [get_bd_pins gtwiz_versal_0/INTF0_TX2_ch_txmaincursor] \
    [get_bd_pins gtwiz_versal_0/INTF0_TX3_ch_txmaincursor]
  connect_bd_net -net const_tx_pre_post_cursor_dout  [get_bd_pins const_tx_pre_post_cursor/dout] \
    [get_bd_pins gtwiz_versal_0/INTF0_TX0_ch_txprecursor] \
    [get_bd_pins gtwiz_versal_0/INTF0_TX1_ch_txprecursor] \
    [get_bd_pins gtwiz_versal_0/INTF0_TX2_ch_txprecursor] \
    [get_bd_pins gtwiz_versal_0/INTF0_TX3_ch_txprecursor] \
    [get_bd_pins gtwiz_versal_0/INTF0_TX0_ch_txpostcursor] \
    [get_bd_pins gtwiz_versal_0/INTF0_TX1_ch_txpostcursor] \
    [get_bd_pins gtwiz_versal_0/INTF0_TX2_ch_txpostcursor] \
    [get_bd_pins gtwiz_versal_0/INTF0_TX3_ch_txpostcursor]
  connect_bd_net -net gt_rst_1  [get_bd_pins gt_rst] [get_bd_pins gtwiz_versal_0/INTF0_rst_all_in]
  connect_bd_net -net gtwiz_freerun_clk_1  [get_bd_pins gtwiz_freerun_clk] [get_bd_pins gtwiz_versal_0/gtwiz_freerun_clk]
  # Reset-done boundary: direct in single mode; dual mode replaces with an AND
  # of done signals from both gtwiz_versal_0 cells (added in the dual block below).
  if { $dual_dcmac == 0 } {
    connect_bd_net -net gtwiz_versal_0_INTF0_rst_rx_done_out  [get_bd_pins gtwiz_versal_0/INTF0_rst_rx_done_out] [get_bd_pins gt_rst_rx_done]
    connect_bd_net -net gtwiz_versal_0_INTF0_rst_tx_done_out  [get_bd_pins gtwiz_versal_0/INTF0_rst_tx_done_out] [get_bd_pins gt_rst_tx_done]
  }
  connect_bd_net -net gtwiz_versal_INTF0_RX0_ch_rxdata  [get_bd_pins gtwiz_versal_0/INTF0_RX0_ch_rxdata] [get_bd_pins rx_data_0]
  connect_bd_net -net gtwiz_versal_INTF0_RX1_ch_rxdata  [get_bd_pins gtwiz_versal_0/INTF0_RX1_ch_rxdata] [get_bd_pins rx_data_1]
  connect_bd_net -net gtwiz_versal_INTF0_RX2_ch_rxdata  [get_bd_pins gtwiz_versal_0/INTF0_RX2_ch_rxdata] [get_bd_pins rx_data_2]
  connect_bd_net -net gtwiz_versal_INTF0_RX3_ch_rxdata  [get_bd_pins gtwiz_versal_0/INTF0_RX3_ch_rxdata] [get_bd_pins rx_data_3]
  connect_bd_net -net gtwiz_versal_INTF0_RX_clr_out  [get_bd_pins gtwiz_versal_0/INTF0_RX_clr_out] [get_bd_pins mbufg_rx/MBUFG_GT_CLR]
  connect_bd_net -net gtwiz_versal_INTF0_RX_clrb_leaf_out  [get_bd_pins gtwiz_versal_0/INTF0_RX_clrb_leaf_out] [get_bd_pins mbufg_rx/MBUFG_GT_CLRB_LEAF]
  connect_bd_net -net gtwiz_versal_INTF0_TX_clr_out  [get_bd_pins gtwiz_versal_0/INTF0_TX_clr_out] [get_bd_pins mbufg_tx/MBUFG_GT_CLR]
  connect_bd_net -net gtwiz_versal_INTF0_TX_clrb_leaf_out  [get_bd_pins gtwiz_versal_0/INTF0_TX_clrb_leaf_out] [get_bd_pins mbufg_tx/MBUFG_GT_CLRB_LEAF]
  connect_bd_net -net gtwiz_versal_QUAD0_RX0_outclk  [get_bd_pins gtwiz_versal_0/QUAD0_RX0_outclk] [get_bd_pins mbufg_rx/MBUFG_GT_I]
  connect_bd_net -net gtwiz_versal_QUAD0_TX0_outclk  [get_bd_pins gtwiz_versal_0/QUAD0_TX0_outclk] [get_bd_pins mbufg_tx/MBUFG_GT_I]
  connect_bd_net -net mbufg_rx_MBUFG_GT_O1  [get_bd_pins mbufg_rx/MBUFG_GT_O1] [get_bd_pins rx_clk]
  connect_bd_net -net mbufg_rx_MBUFG_GT_O2  [get_bd_pins mbufg_rx/MBUFG_GT_O2] \
    [get_bd_pins gtwiz_versal_0/QUAD0_RX0_usrclk] \
    [get_bd_pins gtwiz_versal_0/QUAD0_RX1_usrclk] \
    [get_bd_pins gtwiz_versal_0/QUAD0_RX2_usrclk] \
    [get_bd_pins gtwiz_versal_0/QUAD0_RX3_usrclk] \
    [get_bd_pins rx_clk_alt]
  connect_bd_net -net mbufg_tx_MBUFG_GT_O1  [get_bd_pins mbufg_tx/MBUFG_GT_O1] [get_bd_pins tx_clk]
  connect_bd_net -net mbufg_tx_MBUFG_GT_O2  [get_bd_pins mbufg_tx/MBUFG_GT_O2] \
    [get_bd_pins gtwiz_versal_0/QUAD0_TX0_usrclk] \
    [get_bd_pins gtwiz_versal_0/QUAD0_TX1_usrclk] \
    [get_bd_pins gtwiz_versal_0/QUAD0_TX2_usrclk] \
    [get_bd_pins gtwiz_versal_0/QUAD0_TX3_usrclk] \
    [get_bd_pins tx_clk_alt]

  ##############################################################################
  # Dual-DCMAC additions: second gtwiz_versal cell for the partner GT quad.
  #
  # V80 hardware: each dual-DCMAC pair uses ONE physical refclk pin shared
  # across both quads. The shared refclk arrives on this hier's `gt_ref_clk`
  # input (driven by a single IBUFDS upstream) and fans out to both
  # gtwiz_versal cells' QUAD0_GTREFCLK0 inputs. Both cells declare matching
  # QUAD0_REFCLK_STRING so Vivado consolidates to a single buffer.
  #
  # Per-quad MBUFG_GT pairs are required even with shared refclk — each quad
  # has its own PLL/CDR producing its own user clocks. QUAD1's user clocks
  # stay internal to this hier (the boundary tx_clk/rx_clk/*_alt continue to
  # come from QUAD0 only — DCMAC core uses one set of serdes_clk inputs).
  #
  # Reset-done aggregation: AND the per-quad done signals before exposing on
  # the boundary so dcmac_reset_ctrl waits for both quads.
  ##############################################################################
  if { $dual_dcmac == 1 } {

    # New boundary pins for the second QSFP cage and lanes 4-7.
    create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:gt_rtl:1.0 qsfp_gt1
    create_bd_pin -dir I -from 255 -to 0 tx_data_4
    create_bd_pin -dir I -from 255 -to 0 tx_data_5
    create_bd_pin -dir I -from 255 -to 0 tx_data_6
    create_bd_pin -dir I -from 255 -to 0 tx_data_7
    create_bd_pin -dir O -from 255 -to 0 rx_data_4
    create_bd_pin -dir O -from 255 -to 0 rx_data_5
    create_bd_pin -dir O -from 255 -to 0 rx_data_6
    create_bd_pin -dir O -from 255 -to 0 rx_data_7

    # Second gtwiz_versal cell. Property dict is identical to the first
    # (same QUAD0_REFCLK_STRING with `_unique1` so Vivado consolidates the
    # IBUFDS upstream); physical quad placement is XDC-driven.
    set gtwiz_versal_1 [ create_bd_cell -type ip -vlnv xilinx.com:ip:gtwiz_versal:1.0 gtwiz_versal_1 ]
    set_property -dict [list \
      CONFIG.GT_TYPE {GTM} \
      CONFIG.INTF0_GT_SETTINGS(LR0_SETTINGS) "RXPROGDIV_FREQ_VAL 664.062 RX_REFCLK_FREQUENCY $::dcmac_gt_refclk_mhz TXPROGDIV_FREQ_VAL 664.062 TX_REFCLK_FREQUENCY $::dcmac_gt_refclk_mhz" \
      CONFIG.INTF0_NO_OF_LANES {4} \
      CONFIG.INTF0_PARENTID {undef} \
      CONFIG.INTF0_PRESET {GTM-PAM4_Ethernet_53G} \
      CONFIG.INTF_PARENT_PIN_LIST {QUAD0_RX0 {{}} QUAD0_RX1 {{}} QUAD0_RX2 {{}} QUAD0_RX3 {{}} QUAD0_TX0 {{}} QUAD0_TX1 {{}} QUAD0_TX2 {{}} QUAD0_TX3 {{}}} \
      CONFIG.NO_OF_QUADS {1} \
      CONFIG.QUAD0_CH0_LOOPBACK_EN {true} \
      CONFIG.QUAD0_CH1_LOOPBACK_EN {true} \
      CONFIG.QUAD0_CH2_LOOPBACK_EN {true} \
      CONFIG.QUAD0_CH3_LOOPBACK_EN {true} \
      CONFIG.QUAD0_GT_GPIO_EN {false} \
      CONFIG.QUAD0_REFCLK_STRING {HSCLK0_LCPLLGTREFCLK0 refclk_PROT0_R0_322.265625183611_MHz_unique1} \
    ] $gtwiz_versal_1

    set_property -dict [list \
      CONFIG.INTF0_PARENTID.VALUE_MODE {auto} \
      CONFIG.INTF_PARENT_PIN_LIST.VALUE_MODE {auto} \
    ] $gtwiz_versal_1

    # Per-quad MBUFG pair for the second cell (cross-quad clock sharing is
    # illegal even with shared refclk).
    set mbufg_rx_1 [ create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf:2.2 mbufg_rx_1 ]
    set_property CONFIG.C_BUF_TYPE {MBUFG_GT} $mbufg_rx_1
    set mbufg_tx_1 [ create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf:2.2 mbufg_tx_1 ]
    set_property CONFIG.C_BUF_TYPE {MBUFG_GT} $mbufg_tx_1

    # AND-gates aggregating reset-done across both quads.
    set and_rst_rx_done [ create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:2.0 and_rst_rx_done ]
    set_property -dict [list CONFIG.C_OPERATION {and} CONFIG.C_SIZE {1}] $and_rst_rx_done
    set and_rst_tx_done [ create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:2.0 and_rst_tx_done ]
    set_property -dict [list CONFIG.C_OPERATION {and} CONFIG.C_SIZE {1}] $and_rst_tx_done

    # GT serial port for the second cage.
    connect_bd_intf_net -intf_net Conn1_1 [get_bd_intf_pins gtwiz_versal_1/Quad0_GT_Serial] [get_bd_intf_pins qsfp_gt1]

    # Shared refclk: extend the existing QUAD0_GTREFCLK0_1 net to also drive
    # gtwiz_versal_1. Both cells' matching QUAD0_REFCLK_STRING tells Vivado
    # to consolidate to one IBUFDS_GTE5 upstream.
    connect_bd_net -net QUAD0_GTREFCLK0_1 [get_bd_pins gtwiz_versal_1/QUAD0_GTREFCLK0]

    # Shared free-run clock and gt_rst (single inputs fan out to both cells).
    connect_bd_net -net gtwiz_freerun_clk_1 [get_bd_pins gtwiz_versal_1/gtwiz_freerun_clk]
    connect_bd_net -net gt_rst_1            [get_bd_pins gtwiz_versal_1/INTF0_rst_all_in]

    # Fan out shared constants (loopback, gt_rate, cursors, rxcdrhold/PLL/datapath
    # resets, MBUFG_GT_CE) to the second cell.
    connect_bd_net -net const_0_dout \
      [get_bd_pins gtwiz_versal_1/INTF0_rst_rx_pll_and_datapath_in] \
      [get_bd_pins gtwiz_versal_1/INTF0_rst_tx_datapath_in] \
      [get_bd_pins gtwiz_versal_1/INTF0_rst_tx_pll_and_datapath_in] \
      [get_bd_pins gtwiz_versal_1/INTF0_rst_rx_datapath_in] \
      [get_bd_pins gtwiz_versal_1/INTF0_RX0_ch_rxcdrhold] \
      [get_bd_pins gtwiz_versal_1/INTF0_RX1_ch_rxcdrhold] \
      [get_bd_pins gtwiz_versal_1/INTF0_RX2_ch_rxcdrhold] \
      [get_bd_pins gtwiz_versal_1/INTF0_RX3_ch_rxcdrhold]
    connect_bd_net -net const_gt_rate_dout \
      [get_bd_pins gtwiz_versal_1/INTF0_RX0_ch_rxrate] \
      [get_bd_pins gtwiz_versal_1/INTF0_RX1_ch_rxrate] \
      [get_bd_pins gtwiz_versal_1/INTF0_RX2_ch_rxrate] \
      [get_bd_pins gtwiz_versal_1/INTF0_RX3_ch_rxrate] \
      [get_bd_pins gtwiz_versal_1/INTF0_TX0_ch_txrate] \
      [get_bd_pins gtwiz_versal_1/INTF0_TX1_ch_txrate] \
      [get_bd_pins gtwiz_versal_1/INTF0_TX2_ch_txrate] \
      [get_bd_pins gtwiz_versal_1/INTF0_TX3_ch_txrate]
    connect_bd_net -net const_loopback_dout \
      [get_bd_pins gtwiz_versal_1/QUAD0_ch0_loopback] \
      [get_bd_pins gtwiz_versal_1/QUAD0_ch1_loopback] \
      [get_bd_pins gtwiz_versal_1/QUAD0_ch2_loopback] \
      [get_bd_pins gtwiz_versal_1/QUAD0_ch3_loopback]
    connect_bd_net -net const_tx_main_cursor_dout \
      [get_bd_pins gtwiz_versal_1/INTF0_TX0_ch_txmaincursor] \
      [get_bd_pins gtwiz_versal_1/INTF0_TX1_ch_txmaincursor] \
      [get_bd_pins gtwiz_versal_1/INTF0_TX2_ch_txmaincursor] \
      [get_bd_pins gtwiz_versal_1/INTF0_TX3_ch_txmaincursor]
    connect_bd_net -net const_tx_pre_post_cursor_dout \
      [get_bd_pins gtwiz_versal_1/INTF0_TX0_ch_txprecursor] \
      [get_bd_pins gtwiz_versal_1/INTF0_TX1_ch_txprecursor] \
      [get_bd_pins gtwiz_versal_1/INTF0_TX2_ch_txprecursor] \
      [get_bd_pins gtwiz_versal_1/INTF0_TX3_ch_txprecursor] \
      [get_bd_pins gtwiz_versal_1/INTF0_TX0_ch_txpostcursor] \
      [get_bd_pins gtwiz_versal_1/INTF0_TX1_ch_txpostcursor] \
      [get_bd_pins gtwiz_versal_1/INTF0_TX2_ch_txpostcursor] \
      [get_bd_pins gtwiz_versal_1/INTF0_TX3_ch_txpostcursor]
    connect_bd_net -net MBUFG_GT_CE_1 \
      [get_bd_pins mbufg_rx_1/MBUFG_GT_CE] \
      [get_bd_pins mbufg_tx_1/MBUFG_GT_CE]

    # Lane 4-7 data buses to/from the second cell.
    connect_bd_net -net INTF0_TX0_ch_txdata_2 [get_bd_pins tx_data_4] [get_bd_pins gtwiz_versal_1/INTF0_TX0_ch_txdata]
    connect_bd_net -net INTF0_TX1_ch_txdata_2 [get_bd_pins tx_data_5] [get_bd_pins gtwiz_versal_1/INTF0_TX1_ch_txdata]
    connect_bd_net -net INTF0_TX2_ch_txdata_2 [get_bd_pins tx_data_6] [get_bd_pins gtwiz_versal_1/INTF0_TX2_ch_txdata]
    connect_bd_net -net INTF0_TX3_ch_txdata_2 [get_bd_pins tx_data_7] [get_bd_pins gtwiz_versal_1/INTF0_TX3_ch_txdata]
    connect_bd_net -net gtwiz_versal_1_INTF0_RX0_ch_rxdata [get_bd_pins gtwiz_versal_1/INTF0_RX0_ch_rxdata] [get_bd_pins rx_data_4]
    connect_bd_net -net gtwiz_versal_1_INTF0_RX1_ch_rxdata [get_bd_pins gtwiz_versal_1/INTF0_RX1_ch_rxdata] [get_bd_pins rx_data_5]
    connect_bd_net -net gtwiz_versal_1_INTF0_RX2_ch_rxdata [get_bd_pins gtwiz_versal_1/INTF0_RX2_ch_rxdata] [get_bd_pins rx_data_6]
    connect_bd_net -net gtwiz_versal_1_INTF0_RX3_ch_rxdata [get_bd_pins gtwiz_versal_1/INTF0_RX3_ch_rxdata] [get_bd_pins rx_data_7]

    # Per-quad MBUFG wiring (mirrors the QUAD0/MBUFG pattern; usrclks stay
    # internal — no boundary export for QUAD1).
    connect_bd_net -net gtwiz_versal_1_INTF0_RX_clr_out       [get_bd_pins gtwiz_versal_1/INTF0_RX_clr_out]       [get_bd_pins mbufg_rx_1/MBUFG_GT_CLR]
    connect_bd_net -net gtwiz_versal_1_INTF0_RX_clrb_leaf_out [get_bd_pins gtwiz_versal_1/INTF0_RX_clrb_leaf_out] [get_bd_pins mbufg_rx_1/MBUFG_GT_CLRB_LEAF]
    connect_bd_net -net gtwiz_versal_1_INTF0_TX_clr_out       [get_bd_pins gtwiz_versal_1/INTF0_TX_clr_out]       [get_bd_pins mbufg_tx_1/MBUFG_GT_CLR]
    connect_bd_net -net gtwiz_versal_1_INTF0_TX_clrb_leaf_out [get_bd_pins gtwiz_versal_1/INTF0_TX_clrb_leaf_out] [get_bd_pins mbufg_tx_1/MBUFG_GT_CLRB_LEAF]
    connect_bd_net -net gtwiz_versal_1_QUAD0_RX0_outclk       [get_bd_pins gtwiz_versal_1/QUAD0_RX0_outclk]       [get_bd_pins mbufg_rx_1/MBUFG_GT_I]
    connect_bd_net -net gtwiz_versal_1_QUAD0_TX0_outclk       [get_bd_pins gtwiz_versal_1/QUAD0_TX0_outclk]       [get_bd_pins mbufg_tx_1/MBUFG_GT_I]
    connect_bd_net -net mbufg_rx_1_MBUFG_GT_O2 [get_bd_pins mbufg_rx_1/MBUFG_GT_O2] \
      [get_bd_pins gtwiz_versal_1/QUAD0_RX0_usrclk] \
      [get_bd_pins gtwiz_versal_1/QUAD0_RX1_usrclk] \
      [get_bd_pins gtwiz_versal_1/QUAD0_RX2_usrclk] \
      [get_bd_pins gtwiz_versal_1/QUAD0_RX3_usrclk]
    connect_bd_net -net mbufg_tx_1_MBUFG_GT_O2 [get_bd_pins mbufg_tx_1/MBUFG_GT_O2] \
      [get_bd_pins gtwiz_versal_1/QUAD0_TX0_usrclk] \
      [get_bd_pins gtwiz_versal_1/QUAD0_TX1_usrclk] \
      [get_bd_pins gtwiz_versal_1/QUAD0_TX2_usrclk] \
      [get_bd_pins gtwiz_versal_1/QUAD0_TX3_usrclk]

    # Reset-done aggregation: AND the per-quad done signals onto the boundary.
    connect_bd_net -net gtwiz_versal_0_INTF0_rst_rx_done_out [get_bd_pins gtwiz_versal_0/INTF0_rst_rx_done_out]   [get_bd_pins and_rst_rx_done/Op1]
    connect_bd_net -net gtwiz_versal_1_INTF0_rst_rx_done_out [get_bd_pins gtwiz_versal_1/INTF0_rst_rx_done_out] [get_bd_pins and_rst_rx_done/Op2]
    connect_bd_net -net and_rst_rx_done_Res                  [get_bd_pins and_rst_rx_done/Res]                  [get_bd_pins gt_rst_rx_done]
    connect_bd_net -net gtwiz_versal_0_INTF0_rst_tx_done_out [get_bd_pins gtwiz_versal_0/INTF0_rst_tx_done_out]   [get_bd_pins and_rst_tx_done/Op1]
    connect_bd_net -net gtwiz_versal_1_INTF0_rst_tx_done_out [get_bd_pins gtwiz_versal_1/INTF0_rst_tx_done_out] [get_bd_pins and_rst_tx_done/Op2]
    connect_bd_net -net and_rst_tx_done_Res                  [get_bd_pins and_rst_tx_done/Res]                  [get_bd_pins gt_rst_tx_done]
  }

  # Restore current instance
  current_bd_instance $oldCurInst
}

################################################################
# TOP-LEVEL
################################################################
proc bd_dcmac { parentCell {dcmac_index 0} {dual_dcmac 0} {dcmac_axil 0} {board v80} {nclk_f ""} } {
    # Validate dcmac_index
    if {![string is integer -strict $dcmac_index] || !($dcmac_index == 0 || $dcmac_index == 1)} {
        catch {common::send_gid_msg -ssname BD::TCL -id 2092 -severity "ERROR" \
            "dcmac_index (value: $dcmac_index) must be 0 or 1"}
        return 1
    }
    # Validate dual_dcmac
    if {![string is integer -strict $dual_dcmac] || !($dual_dcmac == 0 || $dual_dcmac == 1)} {
        catch {common::send_gid_msg -ssname BD::TCL -id 2092 -severity "ERROR" \
            "dual_dcmac (value: $dual_dcmac) must be 0 or 1"}
        return 1
    }
    # Validate dcmac_axil
    if {![string is integer -strict $dcmac_axil] || !($dcmac_axil == 0 || $dcmac_axil == 1)} {
        catch {common::send_gid_msg -ssname BD::TCL -id 2092 -severity "ERROR" \
            "dcmac_axil (value: $dcmac_axil) must be 0 or 1"}
        return 1
    }
    # Validate board against the per-board dict from board_config.tcl.
    if { ![dict exists $::_dcmac_board_loc $board] } {
        catch {common::send_gid_msg -ssname BD::TCL -id 2092 -severity "ERROR" \
            "board (value: $board) is not in _dcmac_board_loc; known: [dict keys $::_dcmac_board_loc]"}
        return 1
    }
    # Resolve nclk_f: explicit arg wins, else fall back to global cfg(nclk_f)
    # for Coyote-style callers that set it via base.tcl.
    if { $nclk_f eq "" } {
        upvar #0 cfg cnfg
        if { ![info exists cnfg(nclk_f)] } {
            catch {common::send_gid_msg -ssname BD::TCL -id 2092 -severity "ERROR" \
                "bd_dcmac: nclk_f not provided and cfg(nclk_f) is unset"}
            return 1
        }
        set nclk_f $cnfg(nclk_f)
    }

    # Set up block design. In standalone mode (no BD open), we own the BD
    # lifecycle and create one. In inline mode (BD already open by the
    # caller), we build into the caller's parentCell using pins instead of
    # ports, and skip validate/save/close.
    set inline [_dcmac_bd_open]
    variable design_name
    set design_name dcmac_${dcmac_index}_versal_axis_wrapper
    if { !$inline } {
        create_bd_design $design_name
    }

    if { $parentCell eq "" } {
        set parentCell [get_bd_cells /]
    }

    set parentObj [get_bd_cells $parentCell]
    if { $parentObj == "" } {
        catch {common::send_gid_msg -ssname BD::TCL -id 2090 -severity "ERROR" "Unable to find parent cell <$parentCell>!"}
        return
    }

    set parentType [get_property TYPE $parentObj]
    if { $parentType ne "hier" } {
        catch {common::send_gid_msg -ssname BD::TCL -id 2091 -severity "ERROR" "Parent <$parentObj> has TYPE = <$parentType>. Expected to be <hier>."}
        return
    }

    set oldCurInst [current_bd_instance .]
    current_bd_instance $parentObj

    # Create interface ports/pins (QSFP 0)
    set S_AXIS_0 [_bnd_intf $inline -mode Slave -vlnv xilinx.com:interface:axis_rtl:1.0 S_AXIS_0]
    set_property -dict [ list \
        CONFIG.HAS_TKEEP {1} \
        CONFIG.HAS_TLAST {1} \
        CONFIG.HAS_TREADY {1} \
        CONFIG.HAS_TSTRB {0} \
        CONFIG.LAYERED_METADATA {undef} \
        CONFIG.TDATA_NUM_BYTES {64} \
        CONFIG.TDEST_WIDTH {0} \
        CONFIG.TID_WIDTH {0} \
        CONFIG.TUSER_WIDTH {0} \
    ] $S_AXIS_0

    set M_AXIS_0 [_bnd_intf $inline -mode Master -vlnv xilinx.com:interface:axis_rtl:1.0 M_AXIS_0]
    set_property -dict [ list \
        CONFIG.HAS_TKEEP {1} \
        CONFIG.HAS_TLAST {1} \
        CONFIG.HAS_TREADY {1} \
        CONFIG.HAS_TSTRB {0} \
        CONFIG.LAYERED_METADATA {undef} \
        CONFIG.TDATA_NUM_BYTES {64} \
        CONFIG.TDEST_WIDTH {0} \
        CONFIG.TID_WIDTH {0} \
        CONFIG.TUSER_WIDTH {0} \
    ] $M_AXIS_0

    # Second QSFP top-level interface ports (only when dual_dcmac is enabled)
    if { $dual_dcmac == 1 } {
        set S_AXIS_1 [_bnd_intf $inline -mode Slave -vlnv xilinx.com:interface:axis_rtl:1.0 S_AXIS_1]
        set_property -dict [ list \
            CONFIG.HAS_TKEEP {1} \
            CONFIG.HAS_TLAST {1} \
            CONFIG.HAS_TREADY {1} \
            CONFIG.HAS_TSTRB {0} \
            CONFIG.LAYERED_METADATA {undef} \
            CONFIG.TDATA_NUM_BYTES {64} \
            CONFIG.TDEST_WIDTH {0} \
            CONFIG.TID_WIDTH {0} \
            CONFIG.TUSER_WIDTH {0} \
        ] $S_AXIS_1

        set M_AXIS_1 [_bnd_intf $inline -mode Master -vlnv xilinx.com:interface:axis_rtl:1.0 M_AXIS_1]
        set_property -dict [ list \
            CONFIG.HAS_TKEEP {1} \
            CONFIG.HAS_TLAST {1} \
            CONFIG.HAS_TREADY {1} \
            CONFIG.HAS_TSTRB {0} \
            CONFIG.LAYERED_METADATA {undef} \
            CONFIG.TDATA_NUM_BYTES {64} \
            CONFIG.TDEST_WIDTH {0} \
            CONFIG.TID_WIDTH {0} \
            CONFIG.TUSER_WIDTH {0} \
        ] $M_AXIS_1
    }

    set qsfp_gt_clk [_bnd_intf $inline -mode Slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 qsfp_gt_clk]
    set_property -dict [ list \
        CONFIG.FREQ_HZ $::dcmac_gt_refclk_hz \
    ] $qsfp_gt_clk

    set qsfp_gt0 [_bnd_intf $inline -mode Master -vlnv xilinx.com:interface:gt_rtl:1.0 qsfp_gt0]

    if { $dual_dcmac == 1 } {
        # Second QSFP cage's GT serial port (lanes 4-7).
        set qsfp_gt1 [_bnd_intf $inline -mode Master -vlnv xilinx.com:interface:gt_rtl:1.0 qsfp_gt1]
    }

    # Create scalar ports/pins
    set aresetn [_bnd_pin $inline -dir I -type rst aresetn]

    set aclk [_bnd_pin $inline -dir I -type clk aclk]
    set associated_busif "S_AXIS_0:M_AXIS_0"
    if { $dual_dcmac == 1 } {
        append associated_busif ":S_AXIS_1:M_AXIS_1"
    }
    if { $dcmac_axil == 1 } {
        append associated_busif ":s_axi"
    }
    set_property -dict [list \
        CONFIG.FREQ_HZ [expr {$nclk_f * 1000000}] \
        CONFIG.ASSOCIATED_BUSIF $associated_busif \
        CONFIG.ASSOCIATED_RESET aresetn \
    ] $aclk

    if { $dcmac_axil == 1 } {
        set s_axi [_bnd_intf $inline -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 s_axi]
    }

    # Create instances
    create_hier_cell_gt_wrapper [current_bd_instance .] gt_wrapper ${dual_dcmac}
    create_hier_cell_dcmac_wrapper [current_bd_instance .] dcmac_wrapper ${dcmac_index} ${dual_dcmac} ${dcmac_axil} ${board}
    set datapath_tx_name "datapath_tx_${dcmac_index}"
    set datapath_rx_name "datapath_rx_${dcmac_index}"
    create_hier_cell_datapath_tx [current_bd_instance .] ${datapath_tx_name} ${dcmac_index}
    create_hier_cell_datapath_rx [current_bd_instance .] ${datapath_rx_name} ${dcmac_index}
    if { $dual_dcmac == 1 } {
        set datapath_tx_name_1 "datapath_tx_${dcmac_index}_1"
        set datapath_rx_name_1 "datapath_rx_${dcmac_index}_1"
        create_hier_cell_datapath_tx [current_bd_instance .] ${datapath_tx_name_1} ${dcmac_index}
        create_hier_cell_datapath_rx [current_bd_instance .] ${datapath_rx_name_1} ${dcmac_index}
    }
    create_hier_cell_bd_clock_reset_ctrl [current_bd_instance .] bd_clock_reset_ctrl

    # Create interface connections (use handle variables so this works for
    # both port and pin boundaries — see _bnd_intf above).
    connect_bd_intf_net $qsfp_gt0    [get_bd_intf_pins gt_wrapper/qsfp_gt0]
    connect_bd_intf_net $qsfp_gt_clk [get_bd_intf_pins bd_clock_reset_ctrl/qsfp_gt_clk]

    connect_bd_intf_net $M_AXIS_0 [get_bd_intf_pins ${datapath_rx_name}/m_axis_rx]
    connect_bd_intf_net [get_bd_intf_pins dcmac_wrapper/M_AXIS_0] [get_bd_intf_pins ${datapath_rx_name}/s_axis_rx]

    connect_bd_intf_net $S_AXIS_0 [get_bd_intf_pins ${datapath_tx_name}/s_axis_tx]
    connect_bd_intf_net [get_bd_intf_pins dcmac_wrapper/S_AXIS_0] [get_bd_intf_pins ${datapath_tx_name}/m_axis_tx]

    if { $dual_dcmac == 1 } {
        connect_bd_intf_net $M_AXIS_1 [get_bd_intf_pins ${datapath_rx_name_1}/m_axis_rx]
        connect_bd_intf_net [get_bd_intf_pins dcmac_wrapper/M_AXIS_1] [get_bd_intf_pins ${datapath_rx_name_1}/s_axis_rx]

        connect_bd_intf_net $S_AXIS_1 [get_bd_intf_pins ${datapath_tx_name_1}/s_axis_tx]
        connect_bd_intf_net [get_bd_intf_pins dcmac_wrapper/S_AXIS_1] [get_bd_intf_pins ${datapath_tx_name_1}/m_axis_tx]
    }

    # Create port/pin connections
    if { $dual_dcmac == 1 } {
        connect_bd_net $aclk \
            [get_bd_pins ${datapath_tx_name}/aclk]   [get_bd_pins ${datapath_rx_name}/aclk] \
            [get_bd_pins ${datapath_tx_name_1}/aclk] [get_bd_pins ${datapath_rx_name_1}/aclk]
        connect_bd_net $aresetn \
            [get_bd_pins ${datapath_tx_name}/aresetn] \
            [get_bd_pins ${datapath_tx_name_1}/aresetn] \
            [get_bd_pins bd_clock_reset_ctrl/aresetn]
    } else {
        connect_bd_net $aclk [get_bd_pins ${datapath_tx_name}/aclk] [get_bd_pins ${datapath_rx_name}/aclk]
        connect_bd_net $aresetn [get_bd_pins ${datapath_tx_name}/aresetn] [get_bd_pins bd_clock_reset_ctrl/aresetn]
    }

    connect_bd_net [get_bd_pins dcmac_wrapper/tx_data_0] [get_bd_pins gt_wrapper/tx_data_0]
    connect_bd_net [get_bd_pins dcmac_wrapper/tx_data_1] [get_bd_pins gt_wrapper/tx_data_1]
    connect_bd_net [get_bd_pins dcmac_wrapper/tx_data_2] [get_bd_pins gt_wrapper/tx_data_2]
    connect_bd_net [get_bd_pins dcmac_wrapper/tx_data_3] [get_bd_pins gt_wrapper/tx_data_3]

    connect_bd_net [get_bd_pins gt_wrapper/rx_data_0] [get_bd_pins dcmac_wrapper/rx_data_0]
    connect_bd_net [get_bd_pins gt_wrapper/rx_data_1] [get_bd_pins dcmac_wrapper/rx_data_1]
    connect_bd_net [get_bd_pins gt_wrapper/rx_data_2] [get_bd_pins dcmac_wrapper/rx_data_2]
    connect_bd_net [get_bd_pins gt_wrapper/rx_data_3] [get_bd_pins dcmac_wrapper/rx_data_3]

    if { $dual_dcmac == 1 } {
        # Second QSFP cage GT serial + lane 4-7 data buses.
        connect_bd_intf_net $qsfp_gt1 [get_bd_intf_pins gt_wrapper/qsfp_gt1]

        connect_bd_net [get_bd_pins dcmac_wrapper/tx_data_4] [get_bd_pins gt_wrapper/tx_data_4]
        connect_bd_net [get_bd_pins dcmac_wrapper/tx_data_5] [get_bd_pins gt_wrapper/tx_data_5]
        connect_bd_net [get_bd_pins dcmac_wrapper/tx_data_6] [get_bd_pins gt_wrapper/tx_data_6]
        connect_bd_net [get_bd_pins dcmac_wrapper/tx_data_7] [get_bd_pins gt_wrapper/tx_data_7]

        connect_bd_net [get_bd_pins gt_wrapper/rx_data_4] [get_bd_pins dcmac_wrapper/rx_data_4]
        connect_bd_net [get_bd_pins gt_wrapper/rx_data_5] [get_bd_pins dcmac_wrapper/rx_data_5]
        connect_bd_net [get_bd_pins gt_wrapper/rx_data_6] [get_bd_pins dcmac_wrapper/rx_data_6]
        connect_bd_net [get_bd_pins gt_wrapper/rx_data_7] [get_bd_pins dcmac_wrapper/rx_data_7]
    }

    connect_bd_net [get_bd_pins bd_clock_reset_ctrl/gt_reset] [get_bd_pins gt_wrapper/gt_rst]
    connect_bd_net [get_bd_pins bd_clock_reset_ctrl/gt_ref_clk] [get_bd_pins gt_wrapper/gt_ref_clk]
    connect_bd_net [get_bd_pins gt_wrapper/gt_rst_rx_done] [get_bd_pins bd_clock_reset_ctrl/gt_reset_done_rx]
    connect_bd_net [get_bd_pins gt_wrapper/gt_rst_tx_done] [get_bd_pins bd_clock_reset_ctrl/gt_reset_done_tx]

    if { $dual_dcmac == 1 } {
        connect_bd_net [get_bd_pins bd_clock_reset_ctrl/dcmac_axis_clk] \
        [get_bd_pins dcmac_wrapper/axis_clk] \
        [get_bd_pins ${datapath_tx_name}/dclk] \
        [get_bd_pins ${datapath_rx_name}/dclk] \
        [get_bd_pins ${datapath_tx_name_1}/dclk] \
        [get_bd_pins ${datapath_rx_name_1}/dclk]

        connect_bd_net [get_bd_pins bd_clock_reset_ctrl/axis_resetn] \
        [get_bd_pins dcmac_wrapper/axis_tx_resetn] \
        [get_bd_pins ${datapath_tx_name}/dresetn] \
        [get_bd_pins ${datapath_rx_name}/dresetn] \
        [get_bd_pins ${datapath_tx_name_1}/dresetn] \
        [get_bd_pins ${datapath_rx_name_1}/dresetn] \
        [get_bd_pins dcmac_wrapper/axis_rx_resetn]
    } else {
        connect_bd_net [get_bd_pins bd_clock_reset_ctrl/dcmac_axis_clk] \
        [get_bd_pins dcmac_wrapper/axis_clk] \
        [get_bd_pins ${datapath_tx_name}/dclk] \
        [get_bd_pins ${datapath_rx_name}/dclk]

        connect_bd_net [get_bd_pins bd_clock_reset_ctrl/axis_resetn] \
        [get_bd_pins dcmac_wrapper/axis_tx_resetn] \
        [get_bd_pins ${datapath_tx_name}/dresetn] \
        [get_bd_pins ${datapath_rx_name}/dresetn] \
        [get_bd_pins dcmac_wrapper/axis_rx_resetn]
    }

    connect_bd_net [get_bd_pins gt_wrapper/rx_clk] [get_bd_pins dcmac_wrapper/rx_clk]
    connect_bd_net [get_bd_pins gt_wrapper/tx_clk] [get_bd_pins dcmac_wrapper/tx_clk]
    connect_bd_net [get_bd_pins gt_wrapper/rx_clk_alt] [get_bd_pins dcmac_wrapper/rx_clk_alt]
    connect_bd_net [get_bd_pins gt_wrapper/tx_clk_alt] [get_bd_pins dcmac_wrapper/tx_clk_alt]
    connect_bd_net [get_bd_pins bd_clock_reset_ctrl/dcmac_core_clk] [get_bd_pins dcmac_wrapper/core_clk]
    connect_bd_net [get_bd_pins bd_clock_reset_ctrl/sys_clk] [get_bd_pins dcmac_wrapper/ts_axil_clk] [get_bd_pins gt_wrapper/gtwiz_freerun_clk]

    if { $dcmac_axil == 1 } {
        set sc [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 s_axi_smartconnect]
        set_property -dict [list \
            CONFIG.NUM_SI {1} \
            CONFIG.NUM_MI {1} \
            CONFIG.NUM_CLKS {1} \
        ] $sc

        connect_bd_intf_net $s_axi                         [get_bd_intf_pins $sc/S00_AXI]
        connect_bd_intf_net [get_bd_intf_pins $sc/M00_AXI] [get_bd_intf_pins dcmac_wrapper/s_axi]

        connect_bd_net $aclk \
            [get_bd_pins $sc/aclk] \
            [get_bd_pins dcmac_wrapper/s_axi_aclk]
        connect_bd_net $aresetn \
            [get_bd_pins $sc/aresetn] \
            [get_bd_pins dcmac_wrapper/s_axi_aresetn]
    }

    connect_bd_net [get_bd_pins bd_clock_reset_ctrl/tx_core_reset] [get_bd_pins dcmac_wrapper/tx_core_reset]
    connect_bd_net [get_bd_pins bd_clock_reset_ctrl/tx_chan_flush] [get_bd_pins dcmac_wrapper/tx_channel_flush]
    connect_bd_net [get_bd_pins bd_clock_reset_ctrl/tx_serdes_reset] [get_bd_pins dcmac_wrapper/tx_serdes_reset]

    connect_bd_net [get_bd_pins bd_clock_reset_ctrl/rx_core_reset] [get_bd_pins dcmac_wrapper/rx_core_reset]
    connect_bd_net [get_bd_pins bd_clock_reset_ctrl/rx_chan_flush] [get_bd_pins dcmac_wrapper/rx_channel_flush]
    connect_bd_net [get_bd_pins bd_clock_reset_ctrl/rx_serdes_reset] [get_bd_pins dcmac_wrapper/rx_serdes_reset]

    # Restore current instance. In standalone mode, also validate/save/close;
    # in inline mode the caller owns those.
    current_bd_instance $oldCurInst

    if { !$inline } {
        validate_bd_design
        save_bd_design
        close_bd_design $design_name
    }

    return 0
}

################################################################
# TOP-LEVEL — SLASH-shaped variant
#
# Creates a qsfp_${2i}_n_${2i+1} hierarchy and builds the bd_dcmac contents
# inside it (bd_dcmac runs in inline mode because the BD is open by the time
# it's called). Pins on the new hier are renamed to match SLASH's
# create_hier_cell_qsfp boundary.
################################################################
proc bd_dcmac_qsfp { parentCell {dcmac_index 0} {dual_dcmac 0} {dcmac_axil 0} {board v80} {nclk_f ""} } {
    # Validate dcmac_index / dual_dcmac / dcmac_axil mirroring bd_dcmac.
    foreach { name val } [list dcmac_index $dcmac_index dual_dcmac $dual_dcmac dcmac_axil $dcmac_axil] {
        if {![string is integer -strict $val] || !($val == 0 || $val == 1)} {
            catch {common::send_gid_msg -ssname BD::TCL -id 2092 -severity "ERROR" \
                "bd_dcmac_qsfp: $name (value: $val) must be 0 or 1"}
            return 1
        }
    }
    # Validate board against the per-board dict from board_config.tcl.
    if { ![dict exists $::_dcmac_board_loc $board] } {
        catch {common::send_gid_msg -ssname BD::TCL -id 2092 -severity "ERROR" \
            "bd_dcmac_qsfp: board (value: $board) is not in _dcmac_board_loc; known: [dict keys $::_dcmac_board_loc]"}
        return 1
    }

    set inline [_dcmac_bd_open]
    set design_name dcmac_${dcmac_index}_versal_axis_wrapper
    if { !$inline } {
        create_bd_design $design_name
    }

    # Resolve parent: caller-supplied, else the BD root.
    if { $parentCell eq "" } {
        set parentCell [get_bd_cells /]
    }
    set parentObj [get_bd_cells $parentCell]
    if { $parentObj eq "" } {
        catch {common::send_gid_msg -ssname BD::TCL -id 2090 -severity "ERROR" \
            "bd_dcmac_qsfp: unable to find parent cell <$parentCell>"}
        return 1
    }

    # Save & switch context so the new hier lands inside parentObj.
    set oldCurInst [current_bd_instance .]
    current_bd_instance $parentObj

    set qsfp_lo        [expr {$dcmac_index * 2}]
    set qsfp_hi        [expr {$qsfp_lo + 1}]
    set qsfp_hier_name "qsfp_${qsfp_lo}_n_${qsfp_hi}"
    set qsfp_hier      [create_bd_cell -type hier $qsfp_hier_name]

    # Build bd_dcmac contents INSIDE the qsfp hier. A BD is open at this
    # point, so bd_dcmac runs in inline mode (uses pins, no lifecycle).
    set rc [bd_dcmac $qsfp_hier $dcmac_index $dual_dcmac $dcmac_axil $board $nclk_f]
    if { $rc != 0 } {
        current_bd_instance $oldCurInst
        return $rc
    }

    current_bd_instance [get_bd_cells ${qsfp_hier_name}]
    set clk_free [create_bd_pin -dir I -type clk freerunning_clk]
    current_bd_instance $parentObj

    # Enter bd_clock_reset_ctrl: add input pin and rewire dcmac_reset_ctrl/sys_clk
    current_bd_instance [get_bd_cells ${qsfp_hier_name}/bd_clock_reset_ctrl]
    create_bd_pin -dir I -type clk freerunning_clk
    disconnect_bd_net [get_bd_nets -of_objects [get_bd_pins dcmac_reset_ctrl/sys_clk]] \
        [get_bd_pins dcmac_reset_ctrl/sys_clk]
    connect_bd_net [get_bd_pins freerunning_clk] [get_bd_pins dcmac_reset_ctrl/sys_clk]
    current_bd_instance $parentObj

    # Wire top-level pin into bd_clock_reset_ctrl and replace sys_clk external sinks
    connect_bd_net $clk_free [get_bd_pins ${qsfp_hier_name}/bd_clock_reset_ctrl/freerunning_clk]

    disconnect_bd_net [get_bd_nets -of_objects [get_bd_pins ${qsfp_hier_name}/bd_clock_reset_ctrl/sys_clk]] \
        [get_bd_pins ${qsfp_hier_name}/bd_clock_reset_ctrl/sys_clk] \
        [get_bd_pins ${qsfp_hier_name}/dcmac_wrapper/ts_axil_clk] \
        [get_bd_pins ${qsfp_hier_name}/gt_wrapper/gtwiz_freerun_clk]
    delete_bd_objs [get_bd_pins ${qsfp_hier_name}/bd_clock_reset_ctrl/sys_clk]
    set_property CONFIG.CLKOUT_USED {true,true,false,false,false,false,false} \
        [get_bd_cells ${qsfp_hier_name}/bd_clock_reset_ctrl/clk_wizard_dcmac]

    connect_bd_net $clk_free \
        [get_bd_pins ${qsfp_hier_name}/dcmac_wrapper/ts_axil_clk] \
        [get_bd_pins ${qsfp_hier_name}/gt_wrapper/gtwiz_freerun_clk]

    if { $dcmac_axil == 1 } {
        set s_axi_aclk_net [get_bd_nets -of_objects [get_bd_pins ${qsfp_hier_name}/dcmac_wrapper/s_axi_aclk]]
        disconnect_bd_net $s_axi_aclk_net \
            [get_bd_pins ${qsfp_hier_name}/dcmac_wrapper/s_axi_aclk] \
            [get_bd_pins ${qsfp_hier_name}/s_axi_smartconnect/aclk]
        connect_bd_net $clk_free \
            [get_bd_pins ${qsfp_hier_name}/dcmac_wrapper/s_axi_aclk] \
            [get_bd_pins ${qsfp_hier_name}/s_axi_smartconnect/aclk]
    }

    # Boundary pin names (S_AXIS_<idx>, M_AXIS_<idx>, qsfp_gt_clk, qsfp_gt0/1)
    # are produced natively by bd_dcmac — no post-hoc rename needed here.
    # aclk, aresetn, and s_axi keep their Coyote names; consumers wire by name.

    # No external port promotion: SLASH (the inline consumer) wires its own BD
    # signals to the qsfp hier's pins by name. In standalone mode the BD ends
    # up with just the qsfp hier and no external boundary — useful for shape
    # inspection in the GUI; not suitable for `make_wrapper` consumption.

    current_bd_instance $oldCurInst

    if { !$inline } {
        # Skip validate_bd_design: with no external port promotion the qsfp
        # hier's clock/reset/AXIS pins are intentionally dangling at the BD
        # boundary, which validate would flag as critical errors. Save and
        # close so the BD persists for GUI inspection.
        save_bd_design
        close_bd_design $design_name
    }

    return 0
}
