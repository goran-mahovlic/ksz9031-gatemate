## Phase 3 Timing Constraints
## Only clk_125 matters; 25 MHz input clock is just fed to PLL.
create_clock -period 40.0 [get_ports clk_25mhz]
create_clock -period 8.0 [get_ports clk_125]
