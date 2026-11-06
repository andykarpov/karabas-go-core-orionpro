`timescale 1ns / 1ps
`default_nettype wire

/*
 orion_video.v

 The screen of the Orion read straight from the SRAM as VESA 800 x 600 at 60 Hz (40.0 MHz, 1056 x
 628, positive syncs), no frame buffer. A point of the Orion is 2 x 2 output pixels: the picture
 of 384 x 256 is 768 x 512 in the middle (x 16..783, y 44..555), the rest is black.

 Wide screens (w512, port FA D7: 64 cells; w480, port F8 D7: 60 cells): 3 output pixels for 2
 points, 768 and 720 pixels wide, the points are 2, 1, 2, 1 pixels in turn.

 A cell of 8 points is 16 clocks (12 on a wide screen). Its 16-bit read (pixels in page 0, colours
 in page 1, the two lanes of one SRAM address) is asked one cell before it shows, and the word is
 loaded into the shift registers at the start of the cell. orion_sram answers within 6 clocks.

 The screen address {~vpage, column, row}: screen 0 at C000. vmode D2..0 as written to port F8:
 000 mono, 001 mono palette 2, 01x blank, 100 / 101 four colours, 11x sixteen colours by cells
 (pixel 1: low tetrade of the colour byte, 0: high), with D3 the colour byte is the port FC
 (pseudocolour). Colour bits are IRGB, they go through the palette (orion_pal).

 With D4 (the modes of the Orion-PRO, D2 = 0 RGB, 1 RGBI) a point has one bit of each plane: R and B
 in the word at the base, G and I in the word 4000 above it, two screens only (bit 0 of the screen
 number is taken as 1). So a cell has two reads, at its clocks 0 and 4: a wide cell of 12 clocks
 gets the second word by clock 10.
*/

module orion_video (
	input wire clk,
	input wire [4:0] vmode,
	input wire [1:0] vpage,
	input wire w512,
	input wire w480,
	input wire [7:0] pcolor,
	input wire [2:0] pal_we,
	input wire [7:0] pal_d,

	output wire vid_req,
	output wire [20:0] vid_addr,
	input wire [15:0] vid_dout,
	input wire vid_valid,

	output reg [23:0] rgb = 24'd0,
	output reg hs = 1'b0,
	output reg vs = 1'b0,
	output reg de = 1'b0
);

parameter H_TOTAL = 1056, H_VISIBLE = 800, H_SYNC = 840, H_SYNC_END = 968;
parameter V_TOTAL = 628, V_VISIBLE = 600, V_SYNC = 601, V_SYNC_END = 605;
parameter V_TOP = 44;     // the first line of the picture

reg [10:0] hcnt = 11'd0;
reg [9:0] vcnt = 10'd0;
always @(posedge clk) begin
	if (hcnt == H_TOTAL - 1) begin
		hcnt <= 11'd0;
		vcnt <= (vcnt == V_TOTAL - 1) ? 10'd0 : vcnt + 10'd1;
	end
	else
		hcnt <= hcnt + 11'd1;
end

wire [9:0] vrel = vcnt - V_TOP;
wire in_y = vcnt >= V_TOP && vcnt < V_TOP + 512;
wire [7:0] row = vrel[8:1];

wire wide = w512 | w480;
wire [3:0] cell_last = wide ? 4'd11 : 4'd15;              // clocks of a cell - 1
wire [6:0] cells = w512 ? 7'd64 : w480 ? 7'd60 : 7'd48;
wire [10:0] x_fetch = w512 ? 11'd4 : w480 ? 11'd28 : 11'd0; // a cell before the first one shows

reg [3:0] ph = 4'd0;
reg [6:0] col = 7'd0;
reg run = 1'b0;
wire line_start = hcnt == x_fetch;
always @(posedge clk) begin
	if (line_start) begin
		run <= in_y;
		ph <= 4'd0;
		col <= 7'd0;
	end
	else if (ph == cell_last) begin
		ph <= 4'd0;
		if (run) begin
			col <= col + 7'd1;
			if (col == cells)
				run <= 1'b0;
		end
	end
	else
		ph <= ph + 4'd1;
end

wire cell_start = ph == 4'd0;
wire live = run || (line_start && in_y);
wire [6:0] col_now = line_start ? 7'd0 : col;

wire ega = vmode[4];
wire second = ega && ph == 4'd4;
wire [1:0] base = ega ? { ~vpage[1], second } : ~vpage;
assign vid_req = live && (cell_start || second) && col_now < cells;
assign vid_addr = { 5'd0, base, col_now[5:0], row };

reg [15:0] hold = 16'd0, hold2 = 16'd0;
reg got = 1'b0;               // the first word of the cell is in
always @(posedge clk) begin
	if (cell_start)
		got <= 1'b0;
	if (vid_valid) begin
		got <= 1'b1;
		if (got)
			hold2 <= vid_dout;
		else
			hold <= vid_dout;
	end
end

// the word asked in cell n shows in cell n + 1
wire show = live && col_now != 7'd0;
wire shift = wide ? (ph == 4'd2 || ph == 4'd3 || ph == 4'd5 || ph == 4'd6 || ph == 4'd8 || ph == 4'd9 || ph == 4'd11)
                  : (ph[0] == 1'b0 && ph != 4'd0);
reg [7:0] pix = 8'd0, cpl = 8'd0, attr = 8'd0, gpl = 8'd0, ipl = 8'd0;
always @(posedge clk) begin
	if (cell_start) begin
		pix <= show ? hold[7:0] : 8'd0;
		cpl <= show ? hold[15:8] : 8'd0;
		attr <= !show ? 8'd0 : vmode[3] ? pcolor : hold[15:8];
		gpl <= show ? hold2[7:0] : 8'd0;
		ipl <= show ? hold2[15:8] : 8'd0;
	end
	else if (shift) begin
		pix <= { pix[6:0], 1'b0 };
		cpl <= { cpl[6:0], 1'b0 };
		gpl <= { gpl[6:0], 1'b0 };
		ipl <= { ipl[6:0], 1'b0 };
	end
end

reg [3:0] code;
always @* begin
	if (vmode[4])
		code = { vmode[2] & ipl[7], pix[7], gpl[7], cpl[7] };
	else case (vmode[2:0])
		3'b000: code = pix[7] ? 4'hA : 4'h0;
		3'b001: code = pix[7] ? 4'hE : 4'h9;
		3'b100: case ({ pix[7], cpl[7] })
				2'b00: code = 4'h0;
				2'b01: code = 4'hC;
				2'b10: code = 4'hA;
				2'b11: code = 4'h9;
			endcase
		3'b101: case ({ pix[7], cpl[7] })
				2'b00: code = 4'hB;
				2'b01: code = 4'hF;
				2'b10: code = 4'hE;
				2'b11: code = 4'hD;
			endcase
		3'b110, 3'b111: code = pix[7] ? attr[3:0] : attr[7:4];
		default: code = 4'h0;
	endcase
end

wire [23:0] pal_rgb;
orion_pal pal (.clk(clk), .we(pal_we), .din(pal_d), .idx({ code[1], code[2], code[0], code[3] }), .rgb(pal_rgb));

// the pixel of hcnt is out two clocks later: the shift register, then rgb
reg de_d = 1'b0, hs_d = 1'b0, vs_d = 1'b0;
always @(posedge clk) begin
	de_d <= hcnt < H_VISIBLE && vcnt < V_VISIBLE;
	hs_d <= hcnt >= H_SYNC && hcnt < H_SYNC_END;
	vs_d <= vcnt >= V_SYNC && vcnt < V_SYNC_END;
	de <= de_d;
	hs <= hs_d;
	vs <= vs_d;
	rgb <= pal_rgb;
end

endmodule
