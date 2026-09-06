#############################################################################
# run.tcl — Genus synthesis run script
# Design : mac_system_top  (MAC Accelerator IP)
# Flow   : Genus, GPDK090, DFT deferred (RTL-to-GDS only)
# Author : Vivek Singh | Nirma University
#
# Structure mirrors the nn_core4 run.tcl reference — same command order
# throughout — with ONE deliberate upgrade: 3 corners (SS/FF/TT), not
# the reference's generic 2 (slow/fast). SS drives setup_view, FF drives
# hold_view, TT drives a separate power_view for report_power. Corner
# filenames (ss.lib/ff.lib/tt.lib) are PLACEHOLDERS — confirm real
# filenames from your kit and swap in; the reference only ever showed
# slow.lib/fast.lib, so a 3rd typical corner may or may not exist as a
# separate file for you. Library search path kept as-written in the
# reference either way — edit to your actual install location.
#
# Two more differences from the nn_core4 reference, both intentional:
#   1. macdft.v is a single flattened file (mac_system_top + all 12
#      sub-modules in one file) — read_hdl below is one filename, not
#      the 21-file list nn_core4 needed. Rename macdft.txt -> macdft.v
#      (or edit the read_hdl line) if your local copy is still .txt.
#   2. No mem4-style blackbox/avoid_feedback line — sync_fifo's memory
#      array is a plain, fully-defined register array, nothing here
#      needs black-boxing the way nn_core4's empty mem4 did.
#############################################################################
set DESIGN_NAME mac_system_top

# --- Library setup — paths kept as-written in the nn_core4 reference ---
set_db lib_search_path {/home/install/FOUNDRY/digital/90nm/dig/lib}
set_db init_hdl_search_path ./
set_db library {slow.lib fast.lib}
set_db auto_ungroup none

# --- MMMC: library sets and delay corners ---
# 3 corners, not 2 — SS/FF/TT, not just the generic slow/fast the
# nn_core4 reference used. PLACEHOLDER FILENAMES (ss.lib/ff.lib/tt.lib):
# your kit's real files might literally be slow.lib=SS, fast.lib=FF with
# no typical shipped at all, or might be named ss_1p0v_125c.lib style —
# check /home/install/FOUNDRY/digital/90nm/dig/lib/ and swap in the real
# names. Structure is correct regardless of what they're actually called.
create_library_set -name ss_lib -timing {slow.lib}
create_library_set -name ff_lib -timing {fast.lib}
create_library_set -name tt_lib -timing {typical.lib}

create_timing_condition -name ss_tc -library_sets {ss_lib}
create_timing_condition -name ff_tc -library_sets {ff_lib}
create_timing_condition -name tt_tc -library_sets {tt_lib}

create_delay_corner -name ss_corner -timing_condition ss_tc
create_delay_corner -name ff_corner -timing_condition ff_tc
create_delay_corner -name tt_corner -timing_condition tt_tc

# --- Read RTL source files ---
# Single file — mac_system_top and all 12 sub-modules (axi4_lite_slave,
# sync_fifo, mac_array, mac_unit, booth_encoder, fa_cell, ha_cell,
# csa_32, wallace_stage3, wallace_stage4, accumulator, output_reg_bank).
read_hdl -language v2001 { macdft.v }

# --- Elaborate top-level design ---
elaborate $DESIGN_NAME
check_design -unresolved
check_design -multiple_driver

# --- Create constraint modes and analysis views ---
create_constraint_mode -name func_mode -sdc_files {constraints.sdc}

create_analysis_view -name setup_view \
    -constraint_mode func_mode \
    -delay_corner ss_corner

create_analysis_view -name hold_view \
    -constraint_mode func_mode \
    -delay_corner ff_corner

create_analysis_view -name power_view \
    -constraint_mode func_mode \
    -delay_corner tt_corner

set_analysis_view -setup {setup_view power_view} -hold {hold_view}
# power_view is deliberately NOT in set_analysis_view — that call is
# setup/hold only. TT gets used explicitly later, at report_power time
# (set_analysis_view -leakage {power_view} or -analysis_view power_view
# on the report_power call itself) — typical corner is for realistic
# power numbers, not timing signoff.

# --- Initialize timing and load constraints ---
init_design

# --- Optimization effort settings ---
set_db syn_global_effort high
set_db syn_generic_effort high
set_db syn_map_effort    high

# --- Enable interactive constraint mode for global SDC attributes ---
set_interactive_constraint_modes {func_mode}
set_max_fanout    20 [current_design]
set_max_transition 0.3 [current_design]

# --- Run Synthesis ---
# NOTE: the nn_core4 reference literally uses "syn_gen" here. Cadence's
# own ASIC Lab Manual documents the full command as "syn_generic".
# Left as syn_gen to match your reference exactly — if it errors on
# your Genus version, swap in syn_generic.
redirect compile.log { syn_gen; syn_map; syn_opt }

# --- Export design database ---
write_db ${DESIGN_NAME}_post_syn.db

# --- Generate Analysis Reports ---
report_qor                    > ${DESIGN_NAME}_qor.rep
report_timing -max_paths 10   > ${DESIGN_NAME}_timing.rep
report_area                   > ${DESIGN_NAME}_area.rep
report_power -view power_view             > ${DESIGN_NAME}_power.rep
report_gates                  > ${DESIGN_NAME}_gates.rep

# --- Write output netlists and constraints ---
write_hdl                  > ${DESIGN_NAME}_netlist.v
write_hdl -generic         > ${DESIGN_NAME}.cdl
write_sdc -view setup_view > ${DESIGN_NAME}_out.sdc
puts "DONE"

