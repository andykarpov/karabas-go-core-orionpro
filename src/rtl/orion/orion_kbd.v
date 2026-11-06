`timescale 1ns / 1ps
`default_nettype wire

/*
 orion_kbd.v

 The PS/2 set 2 scancodes of kg_mcu as the RK-86 keyboard of the Orion: a matrix of 8 columns,
 scan is port A of the PPI (0 = column read), ret its port B (0 = pressed), and three lines on
 the high half of port C: { RUS/LAT (Caps Lock), US (Ctrl), SS (Shift), 1 }, all active low.

 The layout is that of orion2010-zxuno (orionkeyboard.v). A column of the matrix is entry 0, 7, 6 .. 1
 of its table for scan bits 0, 1, 2 .. 7, as there, with the punctuation corrected against OriZEmu.
 The Orion shift is not that of a PC here too (: is a key of its own, its shift gives *, ; gives +,
 - gives =): rz and ru give the crossing of the US character, with or without the Orion shift, for
 the keys that differ. They are taken when the key goes down; its release clears them.

 ms7007: the keyboard of the MS7007 Monitors: the same 8 columns, rows 0..7 on port B and 9..11 on
 D5..7 of port C. The crossings are those of kosarev/orion128 (_keyboard.py), read off the Monitor.
 Its Shift is not that of a PC: a shifted host key gives the crossings of the US character, some
 with the Orion shift (5, 9) as well. They are taken when the key goes down; its release clears
 both crossings of the key. Change ms7007 only during reset.

 joy: a joystick as keys of either layout: the arrows, A Space, B and Start Enter (VK).
*/

module orion_kbd (
	input wire clk,
	input wire reset,
	input wire ms7007,
	input wire [7:0] scancode,
	input wire scancode_upd,    // toggles with each byte
	input wire [12:0] joy,      // the joysticks of kg_mcu (both, or-ed): up, down, left, right, start, A, B in bits 1..7
	input wire [7:0] scan,
	output wire [7:0] ret,
	output wire [3:0] pc_hi
);

reg upd_d = 1'b0;
reg ext = 1'b0, rel = 1'b0;
reg ss = 1'b0, us = 1'b0, rl = 1'b0;
reg [63:0] km = 64'd0;        // { entry, bit }
reg [127:0] ms = 128'd0;      // { column, row }
reg hs = 1'b0;                // the Shift of the host
reg ms_sh = 1'b0;             // the Orion shift of the keys held

reg [6:0] pos;                // { valid, entry, bit }
always @* begin
	case ({ ext, scancode })
		9'h16C: pos = 7'o100;  // Home
		9'h171: pos = 7'o101;  // Delete
		9'h076: pos = 7'o102;  // Esc
		9'h005: pos = 7'o103;  // F1
		9'h006: pos = 7'o104;  // F2
		9'h004: pos = 7'o105;  // F3
		9'h00C: pos = 7'o106;  // F4
		9'h003: pos = 7'o107;  // F5
		9'h022: pos = 7'o110;  // X
		9'h035: pos = 7'o111;  // Y
		9'h01A: pos = 7'o112;  // Z
		9'h054: pos = 7'o113;  // [
		9'h05D: pos = 7'o114;  // backslash
		9'h05B: pos = 7'o115;  // ]
		9'h00E: pos = 7'o116;  // `
		9'h029: pos = 7'o117;  // Space
		9'h04D: pos = 7'o120;  // P
		9'h015: pos = 7'o121;  // Q
		9'h02D: pos = 7'o122;  // R
		9'h01B: pos = 7'o123;  // S
		9'h02C: pos = 7'o124;  // T
		9'h03C: pos = 7'o125;  // U
		9'h02A: pos = 7'o126;  // V
		9'h01D: pos = 7'o127;  // W
		9'h033: pos = 7'o130;  // H
		9'h043: pos = 7'o131;  // I
		9'h03B: pos = 7'o132;  // J
		9'h042: pos = 7'o133;  // K
		9'h04B: pos = 7'o134;  // L
		9'h03A: pos = 7'o135;  // M
		9'h031: pos = 7'o136;  // N
		9'h044: pos = 7'o137;  // O
		9'h01C: pos = 7'o141;  // A
		9'h032: pos = 7'o142;  // B
		9'h021: pos = 7'o143;  // C
		9'h023: pos = 7'o144;  // D
		9'h024: pos = 7'o145;  // E
		9'h02B: pos = 7'o146;  // F
		9'h034: pos = 7'o147;  // G
		9'h03E, 9'h075: pos = 7'o150;  // 8
		9'h046, 9'h07D: pos = 7'o151;  // 9
		9'h07C: pos = 7'o152;          // keypad *
		9'h04C, 9'h079: pos = 7'o153;  // ; (keypad +)
		9'h041: pos = 7'o154;          // ,
		9'h04E, 9'h07B: pos = 7'o155;  // - (keypad -)
		9'h049, 9'h071: pos = 7'o156;  // .
		9'h04A, 9'h14A: pos = 7'o157;  // /
		9'h045, 9'h070: pos = 7'o160;  // 0
		9'h016, 9'h069: pos = 7'o161;  // 1
		9'h01E, 9'h072: pos = 7'o162;  // 2
		9'h026, 9'h07A: pos = 7'o163;  // 3
		9'h025, 9'h06B: pos = 7'o164;  // 4
		9'h02E, 9'h073: pos = 7'o165;  // 5
		9'h036, 9'h074: pos = 7'o166;  // 6
		9'h03D, 9'h06C: pos = 7'o167;  // 7
		9'h00D: pos = 7'o170;          // Tab
		9'h170: pos = 7'o171;          // Insert
		9'h05A, 9'h15A: pos = 7'o172;  // Enter
		9'h066: pos = 7'o173;          // Backspace
		9'h16B: pos = 7'o174;          // Left
		9'h175: pos = 7'o175;          // Up
		9'h174: pos = 7'o176;          // Right
		9'h172: pos = 7'o177;          // Down
		default: pos = 7'o000;
	endcase
end

// RK-86, the keys that differ from a PC: { valid, the Orion shift, entry, bit }; ru with no Shift
// held, rz with Shift held
reg [7:0] ru, rz;
always @* begin
	case ({ ext, scancode })
		9'h055: ru = { 2'b11, 3'd5, 3'd5 };  // =
		9'h052: ru = { 2'b11, 3'd6, 3'd7 };  // '
		default: ru = 8'd0;
	endcase
	case ({ ext, scancode })
		9'h01E: rz = { 2'b10, 3'd4, 3'd0 };  // @
		9'h036: rz = { 2'b10, 3'd1, 3'd6 };  // ^
		9'h03D: rz = { 2'b11, 3'd6, 3'd6 };  // &
		9'h03E: rz = { 2'b11, 3'd5, 3'd2 };  // *
		9'h046: rz = { 2'b11, 3'd5, 3'd0 };  // (
		9'h045: rz = { 2'b11, 3'd5, 3'd1 };  // )
		9'h04C: rz = { 2'b10, 3'd5, 3'd2 };  // :
		9'h055: rz = { 2'b11, 3'd5, 3'd3 };  // +
		9'h052: rz = { 2'b11, 3'd6, 3'd2 };  // "
		default: rz = 8'd0;
	endcase
end
reg rk_force = 1'b0, rk_sh = 1'b0;

// MS7007: { valid, column, row }
reg [7:0] mb;
always @* begin
	case ({ ext, scancode })
		9'h01C: mb = 8'h80 | 8'h44;  // A
		9'h032: mb = 8'h80 | 8'h40;  // B
		9'h021: mb = 8'h80 | 8'h32;  // C
		9'h023: mb = 8'h80 | 8'h31;  // D
		9'h024: mb = 8'h80 | 8'h27;  // E
		9'h02B: mb = 8'h80 | 8'h3B;  // F
		9'h034: mb = 8'h80 | 8'h36;  // G
		9'h033: mb = 8'h80 | 8'h70;  // H
		9'h043: mb = 8'h80 | 8'h47;  // I
		9'h03B: mb = 8'h80 | 8'h2B;  // J
		9'h042: mb = 8'h80 | 8'h34;  // K
		9'h04B: mb = 8'h80 | 8'h30;  // L
		9'h03A: mb = 8'h80 | 8'h54;  // M
		9'h031: mb = 8'h80 | 8'h35;  // N
		9'h044: mb = 8'h80 | 8'h46;  // O
		9'h04D: mb = 8'h80 | 8'h37;  // P
		9'h015: mb = 8'h80 | 8'h4B;  // Q
		9'h02D: mb = 8'h80 | 8'h45;  // R
		9'h01B: mb = 8'h80 | 8'h53;  // S
		9'h02C: mb = 8'h80 | 8'h55;  // T
		9'h03C: mb = 8'h80 | 8'h33;  // U
		9'h02A: mb = 8'h80 | 8'h61;  // V
		9'h01D: mb = 8'h80 | 8'h43;  // W
		9'h022: mb = 8'h80 | 8'h56;  // X
		9'h035: mb = 8'h80 | 8'h42;  // Y
		9'h01A: mb = 8'h80 | 8'h71;  // Z
		9'h045, 9'h070: mb = 8'h80 | 8'h6A;  // 0
		9'h016, 9'h069: mb = 8'h80 | 8'h6B;  // 1
		9'h01E, 9'h072: mb = 8'h80 | 8'h7B;  // 2
		9'h026, 9'h07A: mb = 8'h80 | 8'h0B;  // 3
		9'h025, 9'h06B: mb = 8'h80 | 8'h62;  // 4
		9'h02E, 9'h073: mb = 8'h80 | 8'h72;  // 5
		9'h036, 9'h074: mb = 8'h80 | 8'h02;  // 6
		9'h03D, 9'h06C: mb = 8'h80 | 8'h69;  // 7
		9'h03E, 9'h075: mb = 8'h80 | 8'h79;  // 8
		9'h046, 9'h07D: mb = 8'h80 | 8'h09;  // 9
		9'h049: mb = 8'h80 | 8'h7A;  // .
		9'h041: mb = 8'h80 | 8'h19;  // ,
		9'h04C: mb = 8'h80 | 8'h1B;  // ;
		9'h04A, 9'h14A: mb = 8'h80 | 8'h05;  // /
		9'h04E: mb = 8'h80 | 8'h29;  // -
		9'h055: mb = 8'h80 | 8'h06;  // =
		9'h052: mb = 8'h80 | 8'h10;  // '
		9'h054: mb = 8'h80 | 8'h20;  // [
		9'h05B: mb = 8'h80 | 8'h21;  // ]
		9'h05D: mb = 8'h80 | 8'h60;  // backslash
		9'h029: mb = 8'h80 | 8'h00;  // Space
		9'h05A, 9'h15A: mb = 8'h80 | 8'h0A;  // Enter
		9'h16B: mb = 8'h80 | 8'h50;  // Left
		9'h174: mb = 8'h80 | 8'h67;  // Right
		9'h175: mb = 8'h80 | 8'h75;  // Up
		9'h172: mb = 8'h80 | 8'h65;  // Down
		9'h066: mb = 8'h80 | 8'h64;  // Backspace
		9'h076: mb = 8'h80 | 8'h1A;  // Esc
		9'h00D: mb = 8'h80 | 8'h2A;  // Tab
		9'h005: mb = 8'h80 | 8'h12;  // F1
		9'h006: mb = 8'h80 | 8'h13;  // F2
		9'h004: mb = 8'h80 | 8'h14;  // F3
		9'h00C: mb = 8'h80 | 8'h15;  // F4
		9'h003: mb = 8'h80 | 8'h16;  // F5
		9'h00B: mb = 8'h80 | 8'h73;  // F6 (ISP)
		9'h170: mb = 8'h80 | 8'h03;  // Insert
		9'h16C: mb = 8'h80 | 8'h74;  // Home
		9'h169: mb = 8'h80 | 8'h04;  // End
		default: mb = 8'h00;
	endcase
end

// the shifted symbols: { valid, the Orion shift too, column, row[3:0] }, the column in bits 6:4 of ms
reg [8:0] mz;
wire [2:0] mz_col = mz[6:4];
always @* begin
	case ({ ext, scancode })
		9'h016: mz = 9'h122;  // !
		9'h01E: mz = 9'h141;  // @
		9'h026: mz = 9'h124;  // #
		9'h025: mz = 9'h117;  // $
		9'h02E: mz = 9'h125;  // %
		9'h036: mz = 9'h152;  // ^
		9'h03D: mz = 9'h126;  // &
		9'h03E: mz = 9'h187;  // *
		9'h046: mz = 9'h111;  // (
		9'h045: mz = 9'h101;  // )
		9'h04E: mz = 9'h176;  // _
		9'h055: mz = 9'h163;  // +
		9'h04C: mz = 9'h107;  // :
		9'h052: mz = 9'h123;  // "
		9'h041: mz = 9'h151;  // <
		9'h049: mz = 9'h166;  // >
		9'h04A: mz = 9'h185;  // ?
		9'h054: mz = 9'h1A0;  // {
		9'h05B: mz = 9'h1A1;  // }
		9'h05D: mz = 9'h1E0;  // |
		9'h00E: mz = 9'h1D2;  // ~
		default: mz = 9'h000;
	endcase
end

always @(posedge clk) begin
	upd_d <= scancode_upd;
	if (reset) begin
		ext <= 1'b0;
		rel <= 1'b0;
		ss <= 1'b0;
		us <= 1'b0;
		rl <= 1'b0;
		km <= 64'd0;
		ms <= 128'd0;
		hs <= 1'b0;
		ms_sh <= 1'b0;
		rk_force <= 1'b0;
		rk_sh <= 1'b0;
	end
	else if (scancode_upd != upd_d) begin
		if (scancode == 8'hE0)
			ext <= 1'b1;
		else if (scancode == 8'hF0)
			rel <= 1'b1;
		else begin
			ext <= 1'b0;
			rel <= 1'b0;
			if ({ ext, scancode } == 9'h012 || { ext, scancode } == 9'h059) begin
				ss <= ~rel;
				hs <= ~rel;
				if (rel)
					ms_sh <= 1'b0;
			end
			else if (scancode == 8'h14) begin    // both Ctrl keys
				us <= ~rel;
				ms[{ 3'd5, 4'd10 }] <= ~rel;
			end
			else if ({ ext, scancode } == 9'h058) begin
				rl <= ~rel;
				ms[{ 3'd5, 4'd11 }] <= ~rel;   // FIX, RUS/LAT
			end
			else begin
				if (rel) begin
					if (pos[6]) km[pos[5:0]] <= 1'b0;
					if (ru[7]) km[ru[5:0]] <= 1'b0;
					if (rz[7]) km[rz[5:0]] <= 1'b0;
					rk_force <= 1'b0;
				end
				else if (hs && rz[7]) begin
					km[rz[5:0]] <= 1'b1;
					rk_force <= 1'b1;
					rk_sh <= rz[6];
				end
				else if (!hs && ru[7]) begin
					km[ru[5:0]] <= 1'b1;
					rk_force <= 1'b1;
					rk_sh <= ru[6];
				end
				else if (pos[6])
					km[pos[5:0]] <= 1'b1;
				if (rel) begin
					if (mb[7]) ms[mb[6:0]] <= 1'b0;
					if (mz[8]) ms[{ mz_col, mz[3:0] }] <= 1'b0;
				end
				else if (hs && mz[8]) begin
					ms[{ mz_col, mz[3:0] }] <= 1'b1;
					ms_sh <= mz[7];
				end
				else if (mb[7]) begin
					ms[mb[6:0]] <= 1'b1;
					ms_sh <= hs;
				end
			end
		end
	end
end

// the joystick: pressed while held, on top of the keys
wire j_up = joy[1], j_down = joy[2], j_left = joy[3], j_right = joy[4];
wire j_space = joy[6], j_enter = joy[5] | joy[7];
wire [63:0] kj = km | ({ 63'd0, j_left } << 6'o74) | ({ 63'd0, j_up } << 6'o75) | ({ 63'd0, j_right } << 6'o76) |
                 ({ 63'd0, j_down } << 6'o77) | ({ 63'd0, j_enter } << 6'o72) | ({ 63'd0, j_space } << 6'o17);
wire [127:0] mj = ms | ({ 127'd0, j_left } << 7'h50) | ({ 127'd0, j_right } << 7'h67) | ({ 127'd0, j_up } << 7'h75) |
                  ({ 127'd0, j_down } << 7'h65) | ({ 127'd0, j_enter } << 7'h0A) | ({ 127'd0, j_space } << 7'h00);
function [7:0] col;
	input [2:0] e;
	col = { kj[{ e, 3'd7 }], kj[{ e, 3'd6 }], kj[{ e, 3'd5 }], kj[{ e, 3'd4 }],
	        kj[{ e, 3'd3 }], kj[{ e, 3'd2 }], kj[{ e, 3'd1 }], kj[{ e, 3'd0 }] };
endfunction

wire [7:0] ret_rk = ~( (scan[0] ? 8'd0 : col(3'd0)) | (scan[1] ? 8'd0 : col(3'd7)) |
                       (scan[2] ? 8'd0 : col(3'd6)) | (scan[3] ? 8'd0 : col(3'd5)) |
                       (scan[4] ? 8'd0 : col(3'd4)) | (scan[5] ? 8'd0 : col(3'd3)) |
                       (scan[6] ? 8'd0 : col(3'd2)) | (scan[7] ? 8'd0 : col(3'd1)) );

// MS7007: a column read gives its rows 0..11; the Orion shift is (5, 9)
function [11:0] mc;
	input [2:0] c;
	mc = { mj[{ c, 4'd11 }], mj[{ c, 4'd10 }], mj[{ c, 4'd9 }] | (c == 3'd5 && ms_sh), 1'b0,
	       mj[{ c, 4'd7 }], mj[{ c, 4'd6 }], mj[{ c, 4'd5 }], mj[{ c, 4'd4 }],
	       mj[{ c, 4'd3 }], mj[{ c, 4'd2 }], mj[{ c, 4'd1 }], mj[{ c, 4'd0 }] };
endfunction
wire [11:0] ret_ms = ~( (scan[0] ? 12'd0 : mc(3'd0)) | (scan[1] ? 12'd0 : mc(3'd1)) |
                        (scan[2] ? 12'd0 : mc(3'd2)) | (scan[3] ? 12'd0 : mc(3'd3)) |
                        (scan[4] ? 12'd0 : mc(3'd4)) | (scan[5] ? 12'd0 : mc(3'd5)) |
                        (scan[6] ? 12'd0 : mc(3'd6)) | (scan[7] ? 12'd0 : mc(3'd7)) );

assign ret = ms7007 ? ret_ms[7:0] : ret_rk;
assign pc_hi = ms7007 ? ret_ms[11:8] : { ~rl, ~us, ~(rk_force ? rk_sh : ss), 1'b1 };

endmodule
