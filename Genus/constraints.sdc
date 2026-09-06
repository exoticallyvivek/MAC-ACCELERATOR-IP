#############################################################################
# constraints.sdc
# Design : mac_system_top  (MAC Accelerator IP)
# Flow   : Genus synthesis, GPDK090, DFT deferred (RTL-to-GDS only)
# Author : Vivek Singh | Nirma University
#
# Loaded via a constraint_mode in the Genus run script, same as nn_core4:
#   create_constraint_mode -name func_mode -sdc_files {constraints.sdc}
# and referenced by BOTH the setup_view (slow corner) and hold_view (fast
# corner) analysis views — this file itself is corner-agnostic.
#############################################################################

#-----------------------------------------------------------------------
# Clock
#-----------------------------------------------------------------------
# Single clock domain — ACLK only. No tck / test clock exists in this RTL
# revision (DFT/scan not yet inserted), so no set_clock_groups needed here.
# 10ns/100MHz matches nn_core4's own starting point on this same GPDK090
# kit — NOT a guarantee macdft closes there. This design's Wallace-tree
# CPA and the booth_encoder's pp7 combinational sum (see RTL review) are
# real critical-path candidates nn_core4 didn't have. Re-derive this value
# from report_timing after the first synthesis run, don't leave it at 10.
create_clock -name ACLK -period 10.0 -waveform {0 5.0} [get_ports ACLK]

# Pre-CTS placeholder margin (skew + jitter). Not measured, not in the
# nn_core4 reference either — added here because a first-pass synthesis
# with zero uncertainty modeled is optimistic in a way that won't survive
# contact with real CTS. Tighten once Innovus's actual clock tree exists.
set_clock_uncertainty 0.30 [get_clocks ACLK]
set_clock_transition  0.15 [get_clocks ACLK]

#-----------------------------------------------------------------------
# Input / output delays — grouped by AXI signal role, not one flat number
# like nn_core4.sdc uses. Handshakes gate FSM state transitions directly
# (WR_IDLE/WR_DATA/WR_RESP and RD_IDLE/RD_DATA in axi4_lite_slave), so
# they get the tighter budget; address/data buses tolerate more.
#-----------------------------------------------------------------------
set HANDSHAKE_IN  {AWVALID WVALID BREADY ARVALID RREADY}
set HANDSHAKE_OUT {AWREADY WREADY BVALID BRESP ARREADY RVALID RRESP}
set DATA_IN       {AWADDR WDATA WSTRB ARADDR}
set DATA_OUT      {RDATA}

set_input_delay  2.5 -clock ACLK [get_ports $HANDSHAKE_IN]
set_input_delay  4.0 -clock ACLK [get_ports $DATA_IN]
set_output_delay 2.5 -clock ACLK [get_ports $HANDSHAKE_OUT]
set_output_delay 4.0 -clock ACLK [get_ports $DATA_OUT]

# No real board-level CPU/bus-master spec exists for this design yet, so
# these are reasonable placeholder estimates, not measured numbers.
# set_input_transition used instead of set_driving_cell — real GPDK090
# buffer cell name unknown from this side, check your liberty file and
# swap in a real cell once you're at the Genus terminal.
set_input_transition 0.15 [all_inputs]

# Output load split by group rather than one flat number: handshake
# outputs (AWREADY/WREADY/BVALID/etc.) assumed to drive simple control
# logic on the CPU side, lighter load; RDATA assumed to drive a wider
# bus/register on the receiving end, heavier load. Both still estimates,
# not measured — real numbers come from whatever CPU/bus IP this
# actually attaches to.
set_load 0.02 [get_ports $HANDSHAKE_OUT]
set_load 0.08 [get_ports $DATA_OUT]

#-----------------------------------------------------------------------
# Exceptions
#-----------------------------------------------------------------------
# No false paths declared.
#
# ARESETN is asynchronous and fans out to essentially every flip-flop in
# this design. Tempus checks recovery/removal against ACLK for it
# automatically. nn_core4.sdc false-paths its own reset outright
# (set_false_path -from [get_ports res]) — deliberately NOT doing that
# here: this design has far more FFs hanging off ARESETN, and
# recovery/removal is a real signoff check worth keeping active, not
# noise to suppress. Easy one-line addition later if this turns out to
# be the wrong call for how the course wants it graded.
#
# No multicycle paths declared.
#
# Every pipeline stage in mac_unit — input latch, booth_encoder (incl.
# the pp7 combinational sum), wallace_stage3, wallace_stage4+CPA,
# accumulator — is strictly single-cycle registered, confirmed by RTL
# read-through, not assumed. A multicycle exception here without a
# matching RTL change would make signoff pass while the real hardware
# behavior is wrong — if the CPA/pp7 can't meet the clock period once
# real numbers come back, the fix is architectural (CLA swap, or a real
# RTL pipeline split), not an SDC shortcut.

#-----------------------------------------------------------------------
# Design rule constraints (max_fanout / max_transition) are NOT set here.
#-----------------------------------------------------------------------
# nn_core4's own flow sets these in run.tcl instead, under
# set_interactive_constraint_modes {func_mode} — same 20/0.3 starting
# values carried over there, not duplicated in this file. Worth checking
# specifically post-synthesis: rst_acc and the shared A/B operand bus
# each fan out into 4 parallel mac_unit instances simultaneously (see
# mac_array) — the most likely nets on this design to actually need
# tightening beyond the blanket 20/0.3.
