## Phase 5 Timing Constraints
## 50 MHz PLL clock — plenty for 2.5 MHz MDC + UART-ILA BRAM path.
create_clock -period 40.0 [get_ports clk_25mhz]
create_clock -period 20.0 -name clk_50 [get_nets clk_50]
