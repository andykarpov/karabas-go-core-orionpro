`timescale 1ns / 1ps
`default_nettype wire

/*
 orion_fdd_phys.v

 A physical floppy drive on the connector of the Karabas Go, for the drive A or B of the Orion that
 the firmware puts on it (CMD_IMG_PHYS: slot 4 / 5 on DS0 / DS1): the KR1818VG93 model vg93_top (of
 karabas-go-core-profi, after github.com/demyanenko-d/FD1793_1818VG93) with a data separator and
 the write precompensation, after fdd_glue.v of profi rescaled to 40 MHz (the RCLK half period
 2 us = 80 clocks). The model runs on clk, its CLK is 1 MHz (a 250 kbit/s MFM disk, 5.25" DD or
 3.5" DD); a drive in the MFM of the Orion: 5 sectors of 1024 bytes, 80 tracks, two sides.

 The model takes a written register within two microwords (8 us): hold stops the CPU on an access
 to the controller for 10 us after a write to it (the hosts write sector and command one after
 the other).

 The Go floppy outputs go through inverters: 1 is active on the pins. side: 1 = side 1.
*/

module orion_fdd_phys (
	input wire clk,
	input wire reset,

	input wire sel,              // F700..F703 / F710..F713, and the drive is a physical one
	input wire [1:0] a,
	input wire rd,
	input wire wr,
	input wire [7:0] din,
	output wire [7:0] dout,
	output wire drq,
	output wire hold,
	input wire [1:0] ds,         // the drive line of the selected drive: 1 DS0, 2 DS1
	input wire side,

	input wire FDC_INDEX,
	output reg [1:0] FDC_DRIVE = 2'b00,
	output reg FDC_MOTOR = 1'b0,
	output reg FDC_DIR = 1'b0,
	output reg FDC_STEP = 1'b0,
	output wire FDC_WDATA,
	output reg FDC_WGATE = 1'b0,
	input wire FDC_TR00,
	input wire FDC_WPRT,
	input wire FDC_RDATA,
	output reg FDC_SIDE_N = 1'b0
);

// CLK of the model: 1 MHz square wave
reg [4:0] cdiv = 5'd0;
reg fdc_clk = 1'b0;
always @(posedge clk)
	if (cdiv == 5'd19) begin
		cdiv <= 5'd0;
		fdc_clk <= ~fdc_clk;
	end
	else
		cdiv <= cdiv + 5'd1;
wire fdc_clk_rise = ~fdc_clk & (cdiv == 5'd19);

// a write: 10 CLK periods before the next access
reg [3:0] guard = 4'd0;
reg wr_d = 1'b0;
wire acc = sel & (rd | wr);
always @(posedge clk) begin
	wr_d <= sel & wr & guard == 4'd0;
	if (wr_d && !(sel & wr))
		guard <= 4'd10;
	else if (fdc_clk_rise && guard != 4'd0)
		guard <= guard - 4'd1;
end
assign hold = acc & guard != 4'd0;
wire cs_n = ~sel | (guard != 4'd0);

wire [7:0] dal = (~cs_n & wr) ? din : 8'bZ;
assign dout = dal;

wire intrq, motor, wg, wd, step, dirc, rclk, tg43, early, late, rawread_n;
vg93_top vg93 (
	.SYSCLK(clk),
	.CLK(fdc_clk),
	.MR_n(~reset),
	.CS_n(cs_n),
	.RE_n(~rd),
	.WE_n(~wr),
	.A(a),
	.DAL(dal),
	.DRQ(drq),
	.INTRQ(intrq),
	.STEP(step),
	.DIRC(dirc),
	.EARLY(early),
	.LATE(late),
	.HLD(motor),
	.TG43(tg43),
	.WG(wg),
	.WD(wd),
	.RCLK(rclk),
	.RAWREAD_n(rawread_n),
	.READY(motor),
	.TR00_n(~FDC_TR00),
	.IP_n(~FDC_INDEX),
	.WPRT_n(~FDC_WPRT),
	.HLT(1'b1)
);

// ---- the separator: /RDATA synchronised and filtered, a falling edge is a flux transition; RCLK
// free running, 80 clocks a half period, pulled half way to the window centre on each transition
reg [2:0] rs = 3'b111;
reg rdl = 1'b1, rdl_d = 1'b1;
always @(posedge clk) begin
	rs <= { rs[1:0], ~FDC_RDATA };
	if (rs[2:1] == 2'b00 || rs[2:1] == 2'b11) rdl <= rs[2];
	rdl_d <= rdl;
end
wire pulse = rdl_d && !rdl;
assign rawread_n = !pulse;
reg [6:0] cnt = 7'd0;
reg rclk_r = 1'b0;
wire [7:0] pull = { 1'b0, cnt } + 8'd39;
always @(posedge clk)
	if (pulse) cnt <= pull[7:1];
	else if (cnt == 7'd79) begin cnt <= 7'd0; rclk_r <= ~rclk_r; end
	else cnt <= cnt + 7'd1;
assign rclk = rclk_r;

// ---- write precompensation: delay 4 clocks (100 ns), early / late 1 (3 inside TG43), pulse 9 (225 ns)
reg wd_d = 1'b0;
always @(posedge clk) wd_d <= wd & wg;
wire wd_start = wd & wg & ~wd_d;
reg [4:0] pc = 5'd0;
reg wdata_n = 1'b1;
always @(posedge clk) begin
	if (wd_start)
		case ({ late, tg43, early })
			3'b110: pc <= 5'd16;
			3'b100: pc <= 5'd14;
			3'b011: pc <= 5'd10;
			3'b001: pc <= 5'd12;
			default: pc <= 5'd13;
		endcase
	else if (pc != 5'd0)
		pc <= pc - 5'd1;
	wdata_n <= !(pc != 5'd0 && pc <= 5'd9);
end
assign FDC_WDATA = ~wdata_n;

// the drive pins through flip-flops
always @(posedge clk) begin
	FDC_STEP <= step;
	FDC_DIR <= dirc;
	FDC_WGATE <= wg;
	FDC_MOTOR <= motor;
	FDC_SIDE_N <= side;
	FDC_DRIVE[0] <= motor & (ds == 2'd1);
	FDC_DRIVE[1] <= motor & (ds == 2'd2);
end

endmodule
