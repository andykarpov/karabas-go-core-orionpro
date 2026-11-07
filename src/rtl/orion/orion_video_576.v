`timescale 1ns / 1ps
`default_nettype wire

/*
 orion_video_576.v

 The screen of the Orion as 720 x 576 at 50 Hz (CEA-861 576p: 27.0 MHz, 864 x 625, negative syncs),
 the rate of the original. The other output of the core, next to orion_video (800 x 600 at 60 Hz).

 Two clocks: the SRAM is read on clk (40 MHz), the picture goes out on clk_pix (27 MHz). Each line
 of the Orion (256, two output lines each, y 32..543) is fetched into one half of a line buffer
 while the other half shows: at the start of the output line before it, its 64 words (pixels in
 page 0, colours in page 1, the two lanes of one SRAM address) are read through the video port of
 orion_sram, which takes some 600 clocks of a line of 1280.

 The width: 384 points 3 output pixels for 2 (576, x 72..647), 480 points the same (720, the whole
 line), 512 points one pixel each (512, x 104..615). The colours are those of orion_video.

 The modes with D4 of vmode (orion_video) have two words per cell: the planes R, B and G, I in two
 line buffers, 128 words fetched in a line and a half at most: the half being fetched does not show.

 The registers of the machine (vmode, vpage, w512, w480, pcolor) are taken into clk_pix through two
 flip-flops: they change rarely, a change shows on the next line or two.
*/

module orion_video_576 (
	input wire clk,
	input wire clk_pix,
	input wire en,                 // this output is on: else the fetch stops (the SRAM port is the other one's)
	input wire [4:0] vmode,
	input wire [1:0] vpage,
	input wire w512,
	input wire w480,
	input wire [7:0] pcolor,
	input wire [2:0] pal_we,
	input wire [7:0] pal_d,

	output reg vid_req = 1'b0,
	output reg [20:0] vid_addr = 21'd0,
	input wire [15:0] vid_dout,
	input wire vid_valid,

	output reg [23:0] rgb = 24'd0,
	output reg hs = 1'b0,          // active high here (the top inverts them for the pins)
	output reg vs = 1'b0,
	output reg de = 1'b0
);

localparam H_TOTAL = 864, H_VISIBLE = 720, H_SYNC = 732, H_SYNC_END = 796;
localparam V_TOTAL = 625, V_VISIBLE = 576, V_SYNC = 581, V_SYNC_END = 586;
localparam V_TOP = 32;

// ------------------------------------------------------------------ clk_pix: the timing
reg [9:0] hcnt = 10'd0;
reg [9:0] vcnt = 10'd0;
reg line_tg = 1'b0;           // toggles at each new line, vcnt is that line
always @(posedge clk_pix) begin
	if (hcnt == H_TOTAL - 1) begin
		hcnt <= 10'd0;
		vcnt <= (vcnt == V_TOTAL - 1) ? 10'd0 : vcnt + 10'd1;
		line_tg <= ~line_tg;
	end
	else
		hcnt <= hcnt + 10'd1;
end

// ------------------------------------------------------------------ clk: the fetch
reg [2:0] tg_s = 3'd0;
always @(posedge clk)
	tg_s <= { tg_s[1:0], line_tg };
wire new_line = tg_s[2] != tg_s[1];

reg [9:0] next = 10'd0;
reg busy = 1'b0, waiting = 1'b0;
reg fp = 1'b0;                // the plane: 0 the word at the base, 1 the one 4000 above it
wire ega = vmode[4];
wire [1:0] fbase = ega ? { ~vpage[1], fp } : ~vpage;
reg [6:0] fcol = 7'd0;
reg [7:0] frow = 8'd0;
reg buf_we = 1'b0, buf_p = 1'b0;
reg [6:0] buf_wa = 7'd0;
reg [15:0] buf_wd = 16'd0;
wire [9:0] next_rel = next - V_TOP;

always @(posedge clk) begin
	vid_req <= 1'b0;
	buf_we <= 1'b0;
	if (!en) begin
		busy <= 1'b0;
		waiting <= 1'b0;
	end
	else if (new_line && !busy) begin
		// vcnt is stable for a line by now: the line after it
		next <= (vcnt == V_TOTAL - 1) ? 10'd0 : vcnt + 10'd1;
		busy <= 1'b1;
		waiting <= 1'b0;
		fcol <= 7'd0;
		fp <= 1'b0;
	end
	else if (busy && !waiting && fcol == 7'd0 && !(next >= V_TOP && next < V_TOP + 512 && next_rel[0] == 1'b0))
		busy <= 1'b0;             // not the first line of a row of the Orion: nothing to fetch
	else if (busy && !waiting) begin
		if (fcol == 7'd64) begin
			fcol <= 7'd0;
			fp <= 1'b1;
			if (!ega || fp)
				busy <= 1'b0;
		end
		else begin
			frow <= next_rel[8:1];
			vid_req <= 1'b1;
			vid_addr <= { 5'd0, fbase, fcol[5:0], next_rel[8:1] };
			waiting <= 1'b1;
		end
	end
	else if (busy && vid_valid) begin
		buf_we <= 1'b1;
		buf_p <= fp;
		buf_wa <= { frow[0], fcol[5:0] };
		buf_wd <= vid_dout;
		fcol <= fcol + 7'd1;
		waiting <= 1'b0;
	end
end

wire [15:0] buf_q, buf_q2;
reg [6:0] buf_ra = 7'd0;
kg_sdpram #(.DW(16), .AW(7)) lbuf (
	.clka(clk), .wea(buf_we & ~buf_p), .addra(buf_wa), .dina(buf_wd),
	.clkb(clk_pix), .enb(1'b1), .addrb(buf_ra), .doutb(buf_q)
);
kg_sdpram #(.DW(16), .AW(7)) lbuf2 (
	.clka(clk), .wea(buf_we & buf_p), .addra(buf_wa), .dina(buf_wd),
	.clkb(clk_pix), .enb(1'b1), .addrb(buf_ra), .doutb(buf_q2)
);

// ------------------------------------------------------------------ clk_pix: the picture
reg [4:0] vm_s0 = 5'd0, vm_s = 5'd0;
reg [1:0] w_s0 = 2'd0, w_s = 2'd0;
reg [7:0] pc_s0 = 8'd0, pc_s = 8'd0;
always @(posedge clk_pix) begin
	vm_s0 <= vmode; vm_s <= vm_s0;
	w_s0 <= { w512, w480 }; w_s <= w_s0;
	pc_s0 <= pcolor; pc_s <= pc_s0;
end
wire ww512 = w_s[1];
wire ww480 = w_s[0] & ~w_s[1];

wire [9:0] vrel = vcnt - V_TOP;
wire in_y = vcnt >= V_TOP && vcnt < V_TOP + 512;
wire [9:0] xoff = ww512 ? 10'd104 : ww480 ? 10'd0 : 10'd72;
wire [3:0] cell_last = ww512 ? 4'd7 : 4'd11;
wire [6:0] cells = ww512 ? 7'd64 : ww480 ? 7'd60 : 7'd48;

// the word of cell n is asked two clocks before it shows: the address at the start of the cell
// before (or at xoff - 3 for cell 0), the read a clock later
reg [3:0] ph = 4'd0;
reg [6:0] col = 7'd0;
reg run = 1'b0;
reg [7:0] pix = 8'd0, cpl = 8'd0, attr = 8'd0, gpl = 8'd0, ipl = 8'd0;
wire shift = ww512 ? (ph != cell_last)
                   : (ph == 4'd1 || ph == 4'd2 || ph == 4'd4 || ph == 4'd5 || ph == 4'd7 || ph == 4'd8 || ph == 4'd10);
// a line starting at x 0 is fetched across the end of the line before (hcnt wraps)
wire [9:0] x_pre = (xoff + H_TOTAL - 10'd3) >= H_TOTAL ? xoff + H_TOTAL - 10'd3 - H_TOTAL : xoff + H_TOTAL - 10'd3;
wire [9:0] x_load = (xoff + H_TOTAL - 10'd1) >= H_TOTAL ? xoff + H_TOTAL - 10'd1 - H_TOTAL : xoff + H_TOTAL - 10'd1;
// the line that the cells of x_pre / x_load belong to: the next one when they are at the end of a line
wire pre_next = x_pre >= 10'd720;
wire [9:0] vline = pre_next ? ((vcnt == V_TOTAL - 1) ? 10'd0 : vcnt + 10'd1) : vcnt;
wire [9:0] vline_rel = vline - V_TOP;
wire vline_in = vline >= V_TOP && vline < V_TOP + 512;

reg load_ok = 1'b0;
always @(posedge clk_pix) begin
	if (hcnt == x_pre) begin
		buf_ra <= { vline_rel[1], 6'd0 };
		load_ok <= vline_in;
	end
	if (hcnt == x_load) begin
		run <= load_ok;
		ph <= 4'd0;
		col <= 7'd1;
		pix <= load_ok ? buf_q[7:0] : 8'd0;
		cpl <= load_ok ? buf_q[15:8] : 8'd0;
		attr <= !load_ok ? 8'd0 : vm_s[3] ? pc_s : buf_q[15:8];
		gpl <= load_ok ? buf_q2[7:0] : 8'd0;
		ipl <= load_ok ? buf_q2[15:8] : 8'd0;
		buf_ra <= { buf_ra[6], 6'd1 };
	end
	else if (run && ph == cell_last) begin
		ph <= 4'd0;
		if (col == cells) begin
			run <= 1'b0;
			pix <= 8'd0;
			cpl <= 8'd0;
			attr <= 8'd0;
			gpl <= 8'd0;
			ipl <= 8'd0;
		end
		else begin
			col <= col + 7'd1;
			pix <= buf_q[7:0];
			cpl <= buf_q[15:8];
			attr <= vm_s[3] ? pc_s : buf_q[15:8];
			gpl <= buf_q2[7:0];
			ipl <= buf_q2[15:8];
			buf_ra <= { buf_ra[6], col[5:0] + 6'd1 };
		end
	end
	else if (run) begin
		ph <= ph + 4'd1;
		if (shift) begin
			pix <= { pix[6:0], 1'b0 };
			cpl <= { cpl[6:0], 1'b0 };
			gpl <= { gpl[6:0], 1'b0 };
			ipl <= { ipl[6:0], 1'b0 };
		end
	end
end

reg [3:0] code;
always @* begin
	if (vm_s[4])
		code = { vm_s[2] & ipl[7], pix[7], gpl[7], cpl[7] };
	else case (vm_s[2:0])
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

// the point of a cycle is the pixel of its hcnt: the syncs and rgb one register later together
always @(posedge clk_pix) begin
	de <= hcnt < H_VISIBLE && vcnt < V_VISIBLE;
	hs <= hcnt >= H_SYNC && hcnt < H_SYNC_END;
	vs <= vcnt >= V_SYNC && vcnt < V_SYNC_END;
	rgb <= (hcnt < H_VISIBLE && vcnt < V_VISIBLE) ? pal_rgb : 24'd0;
end

endmodule
