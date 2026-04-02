## Timing Constraints for KSZ9031 GbE on GateMate CCGM1A1
## nextpnr-himbaechel SDC subset: create_clock on ports only
## PLL output clocks (125 MHz) are auto-derived by nextpnr from the CC_PLL primitive.
## CDC false paths (get_clocks) not supported — async FIFOs handle clock domain crossing.

# Input oscillator
create_clock -period 40.0 [get_ports clk_25mhz]

# RX clock from PHY (source-synchronous, 125 MHz)
create_clock -period 8.0 [get_ports eth_rx_clk]
#create_clock -period 40.0 [get_ports eth_rx_clk]

create_clock -period 8.0 [get_ports clk_125]
#create_clock -period 40.0 [get_ports clk_125]

# CDC false paths — async FIFOs use Gray code, safe by design.
# NOTE: nextpnr-himbaechel for GateMate has LIMITED SDC support.
# set_false_path with get_clocks is NOT reliably supported.
# set_clock_groups -asynchronous is also not confirmed supported.
# These constraints are left as comments for documentation purposes.
# The async FIFOs in eth_mac_1g_fifo handle CDC correctly by design.
#
# Intended constraints (for tools that support them):
# set_false_path -from [get_clocks clk_25mhz] -to [get_clocks eth_rx_clk]
# set_false_path -from [get_clocks eth_rx_clk] -to [get_clocks clk_25mhz]
