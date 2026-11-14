// Debug probes for tb_gbe (EXTRA=sim/gbe/dbg.v EXTRA_TOP="-s dbg"); +stop=<us> ends the run early.
module dbg;
integer stop_us;
initial if ($value$plusargs("stop=%d", stop_us)) begin #(stop_us * 1000.0); $display("DBG stop"); $finish; end
always @(posedge tb_gbe.dut.rxc) begin
  if (tb_gbe.dut.phy_inst.sfdA || tb_gbe.dut.phy_inst.sfdB) $display("%t DBG sfdA=%b sfdB=%b sfdS=%b sel=%b", $time, tb_gbe.dut.phy_inst.sfdA, tb_gbe.dut.phy_inst.sfdB, tb_gbe.dut.phy_inst.sfdS, tb_gbe.dut.phy_inst.sel);
  if (tb_gbe.dut.phy_inst.ofirst) $display("%t DBG ofirst space_ok=%b", $time, tb_gbe.dut.phy_inst.space_ok);
  if (tb_gbe.dut.phy_inst.commit) $display("%t DBG commit bad=%b wa=%0d wc=%0d", $time, tb_gbe.dut.phy_inst.bad, tb_gbe.dut.phy_inst.r_wa, tb_gbe.dut.phy_inst.r_wc);
end
reg dv_d = 0;
always @(posedge tb_gbe.dut.clk) begin
  if (tb_gbe.dut.gmii_rx_dv) $write("%h", tb_gbe.dut.gmii_rxd);
  else if (dv_d) $display(" <GMII RX END %0t>", $time);
  dv_d = tb_gbe.dut.gmii_rx_dv;
  if (tb_gbe.dut.core_inst.rx_err_bad_fcs) $display("%t DBG MAC bad FCS", $time);
end
endmodule
module dbg2;
always @(posedge tb_gbe.dut.clk) begin
  if (tb_gbe.dut.core_inst.mac_inst.rx_fifo_axis_tvalid && tb_gbe.dut.core_inst.mac_inst.rx_fifo_axis_tlast)
    $display("%t DBG2 MAC rx last user=%b", $time, tb_gbe.dut.core_inst.mac_inst.rx_fifo_axis_tuser);
  if (tb_gbe.dut.core_inst.mac_inst.eth_mac_1g_inst.axis_gmii_rx_inst.start_packet_int_reg)
    $display("%t DBG2 gmii_rx start, rst=%b rx_rst=%b", $time, tb_gbe.dut.rst, tb_gbe.dut.core_inst.mac_inst.rx_rst);
  if (tb_gbe.dut.core_inst.rx_axis_tvalid && tb_gbe.dut.core_inst.rx_axis_tlast)
    $display("%t DBG2 core rx last ready=%b", $time, tb_gbe.dut.core_inst.rx_axis_tready);
end
endmodule
module dbg3;
initial begin
  #1578000;
  repeat (40) begin
    @(posedge tb_gbe.dut.clk);
    $display("%t DBG3 wv=%b wptr=%0d rptr=%0d empty=%b full=%b rd_en=%b tv=%b tr=%b rst=%b",
      $time, tb_gbe.dut.core_inst.mac_inst.rx_fifo_axis_tvalid, tb_gbe.dut.core_inst.mac_inst.rx_fifo.wr_ptr,
      tb_gbe.dut.core_inst.mac_inst.rx_fifo.rd_ptr, tb_gbe.dut.core_inst.mac_inst.rx_fifo.rd_empty,
      tb_gbe.dut.core_inst.mac_inst.rx_fifo.wr_full, tb_gbe.dut.core_inst.mac_inst.rx_fifo_rd_en,
      tb_gbe.dut.core_inst.rx_axis_tvalid, tb_gbe.dut.core_inst.rx_axis_tready, tb_gbe.dut.core_inst.mac_inst.logic_rst);
  end
  $finish;
end
endmodule
