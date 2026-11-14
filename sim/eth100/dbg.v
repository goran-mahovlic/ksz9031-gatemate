module dbg;
reg ctl_d = 0;
always @(posedge tb_eth100.eth_tx_clk) begin
  if (tb_eth100.eth_tx_ctl) $write("%h", tb_eth100.eth_txd);
  else if (ctl_d) $display(" <END %0t>", $time);
  ctl_d = tb_eth100.eth_tx_ctl;
end
always @(posedge tb_eth100.eth_rx_clk) if (tb_eth100.eth_rx_ctl) $write("%h", tb_eth100.eth_rxd); 
endmodule
