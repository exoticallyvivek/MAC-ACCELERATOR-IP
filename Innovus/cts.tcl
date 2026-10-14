####################################################################
# cts.tcl — Clock Tree Synthesis, mac_system_top
#
# Run this AFTER placement (place_opt_design) is done and saved — CTS
# needs real cell locations to build a tree, matches your Counter_manual
# reference's own sequencing ("After running placement or pre-CTS
# optimization, you run clock tree synthesis").
#
# Structure below is your own reference script, kept as-written where it
# was already correct, with comments added on the 2 steps that matter
# most and aren't obvious from the command names alone.
####################################################################

# --------------------------------------------------
# CREATE SPEC
# --------------------------------------------------
# Pulls clock tree constraints (skew targets, latency targets) straight
# out of the loaded SDC[cite: 5] — this is why constraints.sdc's
# set_clock_uncertainty/set_clock_transition values actually matter here,
# not just at Genus[cite: 5].
create_ccopt_clock_tree_spec -file ccopt.spec

# --------------------------------------------------
# LOAD SPEC
# --------------------------------------------------
source ccopt.spec

# --------------------------------------------------
# CRITICAL: Build Reset Tree (HFNS via CCOpt)
# --------------------------------------------------
# Manually define ARESETN as a tree so CCOpt buffers and balances it.
# This prevents the massive 11,500+ um wire length and RC delay that
# caused the hold optimization engine to abort.
create_ccopt_clock_tree -name ARESETN_tree -source ARESETN

# --------------------------------------------------
# CRITICAL: switch from ideal to propagated clock
# --------------------------------------------------
# Before this line, timing analysis still assumes the IDEAL zero-delay
# clock model from Genus/pre-CTS Innovus[cite: 5]. Without
# this command, ccopt_design can build a real clock tree and it would
# STILL get ignored by STA, which would keep reporting the same
# optimistic ideal-clock numbers as before[cite: 5] — defeating the entire point
# of running CTS[cite: 5]. This is the line that makes the real tree count[cite: 5].
set_interactive_constraint_modes {FUNC_MODE}
set_propagated_clock [all_clocks]

# Ensure the new reset tree is also propagated for accurate removal checks
set_propagated_clock [get_ports ARESETN]

# --------------------------------------------------
# CTS settings
# --------------------------------------------------
# Cell names (BUFX2/BUFX4/BUFX8, INVX1/INVX2/INVX4) match the X-suffix
# drive-strength convention already confirmed real for this GPDK090 kit[cite: 5]
# (AND2X6, AND2X8, ADDFX1, SDFFRHQX all showed up in the actual Genus
# synthesis report) — structurally consistent, but not independently
# verified against gsclib090's real cell list from this side[cite: 5]. Confirm
# these exact names exist before running; if not, swap in whatever your
# .lib actually calls its buffer/inverter cells[cite: 5].
set_ccopt_property buffer_cells {BUFX2 BUFX4 BUFX8}
set_ccopt_property inverter_cells {INVX1 INVX2 INVX4}
set_ccopt_property target_max_trans 0.2

# --------------------------------------------------
# Run CTS
# --------------------------------------------------
ccopt_design
# If you see an error about the clock net not being completely routed,
# that's expected at this stage (matches the Counter_manual's own note)[cite: 5]
# — NanoRoute fixes it during the full routing step later, not here[cite: 5].

saveDesign postCTSopt

# --------------------------------------------------
# POST-CTS OPTIMIZATION
# --------------------------------------------------
# Setup first, then hold — fixing hold before setup risks the setup fix
# undoing the hold fix (buffer insertion for hold can shift setup slack
# the other way); this order avoids re-chasing your own tail[cite: 5].
optDesign -postCTS
optDesign -postCTS -hold

# --------------------------------------------------
# REPORTS
# --------------------------------------------------
report_ccopt_clock_trees      > mac_system_top_cts_trees.rep
report_ccopt_skew_groups      > mac_system_top_cts_skew.rep

setAnalysisMode -checkType setup
report_timing -check_type setup > mac_system_top_postcts_setup.rep

setAnalysisMode -checkType hold
report_timing -check_type hold  > mac_system_top_postcts_hold.rep

report_power                    > mac_system_top_postcts_power.rep
report_constraint -all_violators > mac_system_top_postcts_violators.rep

saveDesign postCTSfinal
