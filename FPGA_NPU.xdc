create_clock -name clk -period 10 [get_ports clk]

# Set clock uncertainty for jitter tolerance
set_clock_uncertainty 0.1 [get_clocks clk]

########################################
# INPUT/OUTPUT DELAY CONSTRAINTS
########################################

# MRF Interface delays
set_input_delay -clock clk 1.0 [get_ports i_mrf_wr_addr]
set_input_delay -clock clk 1.0 [get_ports i_mrf_wr_data]
set_input_delay -clock clk 0.5 [get_ports i_mrf_wr_en]
set_input_delay -clock clk 1.0 [get_ports i_mrf_wr_id]

set_output_delay -clock clk 1.5 [get_ports o_ld_in_wr_rdy]
set_output_delay -clock clk 1.5 [get_ports o_ld_in_wr_rdy1]
set_output_delay -clock clk 1.5 [get_ports o_ld_out_rd_rdy]
set_output_delay -clock clk 1.5 [get_ports o_ld_out_rd_rdy1]

# Instruction Interface delays
set_input_delay -clock clk 1.0 [get_ports i_minst_chain_wr_en]
set_input_delay -clock clk 1.0 [get_ports i_minst_chain_wr_addr]
set_input_delay -clock clk 1.0 [get_ports i_minst_chain_wr_din]

# Loader Interface delays
set_input_delay -clock clk 1.0 [get_ports i_ld_in_wr_en]
set_input_delay -clock clk 1.0 [get_ports i_ld_in_wr_en1]
set_input_delay -clock clk 1.0 [get_ports i_ld_in_wr_din]
set_input_delay -clock clk 1.0 [get_ports i_ld_in_wr_din1]

set_output_delay -clock clk 1.5 [get_ports o_ld_out_rd_dout]
set_output_delay -clock clk 1.5 [get_ports o_ld_out_rd_dout1]

# Control Interface delays
set_input_delay -clock clk 1.0 [get_ports diag_mode]
set_input_delay -clock clk 1.0 [get_ports i_start]
set_input_delay -clock clk 1.0 [get_ports pc_start_offset]
set_output_delay -clock clk 1.5 [get_ports o_done]

########################################
# FALSE PATHS AND MULTICYCLE PATHS
########################################

# False paths for asynchronous resets (if any)
set_false_path -from [get_pins -hierarchical -filter {NAME =~ *rst*}]

# Multicycle paths for slower control logic
set_multicycle_path 2 -from [get_clocks clk] -to [get_pins -hierarchical -filter {NAME =~ *top_sched*}]
set_multicycle_path 2 -from [get_pins -hierarchical -filter {NAME =~ *top_sched*}] -to [get_clocks clk]

# False paths for debug signals (not timing critical)
set_false_path -from [get_pins -hierarchical -filter {NAME =~ *diag*}]
set_false_path -from [get_pins -hierarchical -filter {NAME =~ *debug*}]

########################################
# PLACEMENT CONSTRAINTS
########################################

# Group related logic for better placement
# Place top-level schedulers near clock region center
place_cell -fixed_location X0Y0 [get_cells top_sched] || true
place_cell -fixed_location X1Y0 [get_cells mvu_sched] || true

# Memory blocks placement strategy
# Place MRF RAMs in dedicated memory columns
place_cell -fixed_location X0Y5 [get_cells -hierarchical -filter {NAME =~ *mfu0/mem*} || get_cells -hierarchical -filter {NAME =~ *mfu1/mem*}] || true
place_cell -fixed_location X0Y6 [get_cells -hierarchical -filter {NAME =~ *mfu0_1/mem*} || get_cells -hierarchical -filter {NAME =~ *mfu1_1/mem*} || get_cells -hierarchical -filter {NAME =~ *evrf0/mem*}] || true
place_cell -fixed_location X0Y7 [get_cells -hierarchical -filter {NAME =~ *evrf1/mem*} || get_cells -hierarchical -filter {NAME =~ *ld/mem*} || get_cells -hierarchical -filter {NAME =~ *ld1/mem*}] || true

# DSP placement for compute arrays
# Place MVU tiles in a grid for optimal routing
# This is a placeholder - actual placement would depend on device architecture

########################################
# ROUTING OPTIMIZATION
########################################

# Limit fanout on high-speed signals
set_max_fanout 50 [get_nets -hierarchical -filter {NAME =~ *clk*}]
set_max_fanout 100 [get_nets -hierarchical -filter {NAME =~ *rst*}]

# Control signal routing optimization
set_max_delay 2.5 -from [get_ports i_start] -to [get_pins -hierarchical -filter {NAME =~ *start_delayed*}]
set_max_delay 3.0 -from [get_pins -hierarchical -filter {NAME =~ *top_sched_oinst_wr_en*}] -to [get_pins -hierarchical -filter {NAME =~ *_inst_wr_en*}]

########################################
# POWER OPTIMIZATION
########################################

# Enable clock gating hints (tool-specific)
# These would be vendor-specific attributes in actual implementation

# Set operating conditions for power analysis
set_operating_conditions -typical

# Activity factors for more accurate power estimation
# set_activity -clock clk -rate 0.1 [get_pins -hierarchical -filter {NAME =~ *mvu_tile*}]
# set_activity -clock clk -rate 0.05 [get_pins -hierarchical -filter {NAME =~ *mfu*}]

########################################
# TIMING EXCEPTIONS
########################################

# Disable timing checks on certain critical paths if needed
# set_disable_timing [get_pins -hierarchical -filter {NAME =~ *some_critical_pin*}]

########################################
# COMPLEXITY AND CONGESTION CONTROLS
########################################

# Prevent placement congestion in high-utilization areas
# place_density -ceil 0.8 -area [get_tiles -hierarchical -filter {NAME =~ *central*}]

# Routing congestion mitigation
route_design -effort high -conditional_contine

########################################
# SYNTHESIS AND IMPLEMENTATION DIRECTIVES
########################################

# Synthesis directives for performance
set_directive -unroll 4 [get_loops -hierarchical -filter {NAME =~ *gen_mvu_tiles*}]
set_directive -unroll 8 [get_loops -hierarchical -filter {NAME =~ *gen_signals*}]

# Implementation strategy for timing closure
# set_impl_strategy -directive Explore

########################################
# VALIDATION CONSTRAINTS
########################################

# Validate that constraints are applied correctly
check_timing
report_clock_networks
report_timing_summary -max_paths 10
report_power -hierarchical
