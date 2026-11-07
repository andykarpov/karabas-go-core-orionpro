`timescale 1ns / 1ps
`default_nettype wire

/*
 orion_ide.v

 The IDE of the Orion-PRO on the ports of the Z80, on the images of the mcu (hdf_ata of the modules):
   56     alternate status / device control (CS1, register 6)
   57     the high byte of the data register, a latch
   58     the low byte of the data register: a read takes the word and keeps its high byte for 57, a
          write sends the word with the high byte written to 57 before it
   59-5F  the registers 1..7 (CS0)
 hdf_ata acts at the end of a strobe, the address of the Z80 holds a moment longer.
*/

module orion_ide (
	input wire clk,
	input wire reset,            // the machine

	input wire [7:0] a,          // the port
	input wire rd,               // IN
	input wire wr,               // OUT
	input wire [7:0] din,
	output wire [7:0] dout,
	output wire sel,             // the port is one of these

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

wire cs0 = a[7:3] == 5'b01011;   // 58-5F
wire cs1 = a == 8'h56;
wire hi = a == 8'h57;
assign sel = cs0 | cs1 | hi;

wire ata_rd = rd & (cs0 | cs1);
wire ata_wr = wr & (cs0 | cs1);

wire [15:0] ata_do;
reg [7:0] hi_wr = 8'd0, hi_rd = 8'd0;
always @(posedge clk) begin
	if (wr && hi)
		hi_wr <= din;
	if (rd && a == 8'h58)
		hi_rd <= ata_do[15:8];
end

assign dout = hi ? hi_rd : ata_do[7:0];

hdf_ata #(
	.DEF_HEADS(5'd16),
	.DEF_SPT(8'd63),
	.SYNC_BUS(0)
) ata (
	.clk(clk),
	.reset(1'b0),
	.ata_reset(reset),
	.dev0_en(1'b1),
	.dev(),
	.dev1_here(),
	.a(cs1 ? 3'd6 : a[2:0]),
	.cs_n({ ~cs1, ~cs0 }),
	.rd_n(~ata_rd),
	.wr_n(~ata_wr),
	.din({ hi_wr, din }),
	.dout(ata_do),
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
