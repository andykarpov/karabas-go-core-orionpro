`timescale 1ns / 1ps
`default_nettype wire

/*
 orion_cpu.v

 The Z80 of the machine (T80pa) as one bus. T80pa takes the two edges of its clock as enables: 2.5, 5
 or 10 MHz by speed. In the turbo modes an edge waits while a read is not ready: the SRAM answers in
 up to nine clocks, a state at 10 MHz is four.
*/

module orion_cpu (
	input wire clk,
	input wire reset,
	input wire [1:0] speed,      // the Z80: 0 2.5, 1 5, 2 10 MHz
	input wire rd_ok,
	input wire hold,             // a wait for a slow device: the clock edges stop

	output wire [15:0] addr,
	output wire [7:0] dout,
	input wire [7:0] din,
	output wire mem_rd,
	output wire mem_wr,
	output wire io_rd,
	output wire io_wr,

	input wire int_n,
	output wire inta     // the Z80 takes the interrupt
);

wire [15:0] a_z80;
wire [7:0] do_z80;
wire mreq_n, iorq_n, rd_n, wr_n, m1_n;

wire [3:0] per = speed == 2'd0 ? 4'd15 : speed == 2'd1 ? 4'd7 : 4'd3;
wire [3:0] mid = { 1'b0, per[3:1] };
wire z_rd = ~mreq_n & ~rd_n;
wire z_go = (speed == 2'd0 || !z_rd || rd_ok) && !hold;
reg [3:0] zc = 4'd0;
wire z_edge = zc == per || zc == mid;
always @(posedge clk)
	if (!z_edge)
		zc <= zc + 4'd1;
	else if (z_go)
		zc <= (zc == per) ? 4'd0 : zc + 4'd1;

T80pa #(.Mode(0)) cpuz80 (
	.RESET_n(~reset),
	.CLK(clk),
	.CEN_p(zc == per && z_go),
	.CEN_n(zc == mid && z_go),
	.WAIT_n(1'b1),
	.INT_n(int_n),
	.NMI_n(1'b1),
	.BUSRQ_n(1'b1),
	.M1_n(m1_n),
	.MREQ_n(mreq_n),
	.IORQ_n(iorq_n),
	.RD_n(rd_n),
	.WR_n(wr_n),
	.RFSH_n(),
	.HALT_n(),
	.BUSAK_n(),
	.OUT0(1'b0),
	.A(a_z80),
	.DI(din),
	.DO(do_z80),
	.REG(),
	.DIRSet(1'b0),
	.DIR(212'd0)
);

assign addr = a_z80;
assign dout = do_z80;
assign mem_rd = z_rd;
assign mem_wr = ~mreq_n & ~wr_n;
assign io_rd = ~iorq_n & ~rd_n;
assign io_wr = ~iorq_n & ~wr_n;
assign inta = ~m1_n & ~iorq_n;

endmodule
