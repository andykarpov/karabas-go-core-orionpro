`timescale 1ns / 1ps
`default_nettype wire

/*
 orion_ide.v

 The IDE of S. Akimov on a KR580VV55, "the people's" controller: port A the control lines, C the
 low byte of the data, B the high byte, on the images of the mcu (hdf_ata of the modules). The
 Monitors M35zrkh and AltairDOS have it at F500, where it shares the PPI with the ROM disk, DSDOS at
 F600. Both PPIs are wired here, no OSD item: a PPI with port A as an output drives the lines, and
 the ROM disk needs that port as an input. Port A: D2..0 the register, D3 CS0, D4 CS1, D5 WR, D6 RD,
 D7 RESET, all active high (the inverters of the board).

 The software drops a strobe and the register in one write of port A, hdf_ata takes the end of the
 strobe a clock later, so the register is held for that clock.
*/

module orion_ide (
	input wire clk,
	input wire reset,            // the machine

	input wire f5_on,            // port A of the PPI is an output
	input wire [7:0] f5_ctl,
	input wire [7:0] f5_hi,
	input wire [7:0] f5_lo,
	input wire f6_on,
	input wire [7:0] f6_ctl,
	input wire [7:0] f6_hi,
	input wire [7:0] f6_lo,
	output wire [7:0] do_hi,     // ports B and C of both PPIs, as inputs
	output wire [7:0] do_lo,

	// two indices of img_sdc, [0] master, [1] slave
	input wire [1:0] img_mounted,
	input wire [63:0] img_size,
	output wire [1:0] sdc_rd,
	output wire [1:0] sdc_wr,
	output wire [31:0] sdc_sector,
	input wire sdc_busy,
	input wire sdc_done,
	input wire sdc_error,
	input wire sdc_byte_in_strobe,
	input wire [8:0] sdc_byte_addr,
	input wire [7:0] sdc_byte_in_data,
	output wire [7:0] sdc_byte_out_data
);

wire [7:0] ctl = f5_on ? f5_ctl : f6_on ? f6_ctl : 8'h00;
wire [15:0] dout_wr = f5_on ? { f5_hi, f5_lo } : { f6_hi, f6_lo };
wire strobe = ctl[6] | ctl[5];

reg strobe_d = 1'b0;
reg [4:0] held = 5'd0;
always @(posedge clk) begin
	strobe_d <= strobe;
	if (strobe)
		held <= ctl[4:0];
end
wire [4:0] bus = (strobe_d && !strobe) ? held : ctl[4:0];

wire [15:0] dout;
assign do_hi = dout[15:8];
assign do_lo = dout[7:0];

hdf_ata #(
	.DEF_HEADS(5'd16),
	.DEF_SPT(8'd63),
	.SYNC_BUS(0)
) ata (
	.clk(clk),
	.reset(1'b0),
	.ata_reset(reset | ctl[7]),
	.dev0_en(1'b1),
	.dev(),
	.dev1_here(),
	.a(bus[2:0]),
	.cs_n(~bus[4:3]),
	.rd_n(~ctl[6]),
	.wr_n(~ctl[5]),
	.din(dout_wr),
	.dout(dout),
	.img_mounted(img_mounted),
	.img_size(img_size),
	.sdc_rd(sdc_rd),
	.sdc_wr(sdc_wr),
	.sdc_sector(sdc_sector),
	.sdc_busy(sdc_busy),
	.sdc_done(sdc_done),
	.sdc_error(sdc_error),
	.sdc_byte_in_strobe(sdc_byte_in_strobe),
	.sdc_byte_addr(sdc_byte_addr),
	.sdc_byte_in_data(sdc_byte_in_data),
	.sdc_byte_out_data(sdc_byte_out_data),
	.led()
);

endmodule
