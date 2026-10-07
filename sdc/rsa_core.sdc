# ============================================================
# SDC constraints for rsa_core
# ============================================================

# Create a 10 ns (100 MHz) clock on core_clk.
create_clock -name core_clk -period 4.0 [get_ports core_clk]

# Apply input delay to all inputs except the clock and async reset.
set_input_delay 0.5 -clock core_clk \
    [remove_from_collection [all_inputs] [get_ports {core_clk core_rst}]]

# Apply output delay to all output ports
set_output_delay 0.2 -clock core_clk [all_outputs]

# Do not treat the asynchronous reset as a normal synchronous data path.
set_false_path -from [get_ports core_rst]
