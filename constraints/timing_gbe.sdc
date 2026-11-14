## gbe_top: pad clocks (the PLL outputs gtx / CLK90 are derived by nextpnr from CC_PLL)
create_clock -period 40.0 [get_ports clk_25mhz]
create_clock -period 8.0  [get_ports eth_rx_clk]
