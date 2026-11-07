`timescale 1ns / 1ps
`default_nettype wire

/*
 orion_mouse.v

 The parallel mouse of the Multicard of the Orion-PRO, port 1E, from the USB mouse of kg_mcu. The
 BIOS (MOUS, INMS of ROM1) reads the port as a joystick, all lines active low:
   D0 left, D1 right, D2 down, D3 up, D4 the left button, D5 the right button, D6, D7 = 1.
 It moves the pointer one step for each poll that shows a direction. So the deltas of the USB
 reports are added up, and a direction is shown while its count is not 0; the count goes one unit
 towards 0 every STEP clocks, not on a read (MOUS reads the port until two reads agree).
*/

module orion_mouse #(
	parameter STEP = 80000          // 2 ms of 40 MHz for a unit of the USB mouse
) (
	input wire clk,
	input wire reset,
	input wire [7:0] ms_x,          // a delta, right is positive
	input wire [7:0] ms_y,          // a delta, down is positive
	input wire [2:0] ms_b,          // the buttons: 0 left, 1 right
	input wire ms_upd,              // toggles with each report
	output wire [7:0] port
);

reg upd_d = 1'b0;
reg [10:0] cx = 11'd0, cy = 11'd0;   // the counts, signed
reg [16:0] t = 17'd0;
wire tick = t == STEP - 1;

// a sum that stops at the ends of the range
function [10:0] sat;
	input [10:0] c;
	input [7:0] d;
	reg [11:0] s;
	begin
		s = { c[10], c } + { {4{d[7]}}, d };
		sat = (s[11] != s[10]) ? (s[11] ? 11'h400 : 11'h3FF) : s[10:0];
	end
endfunction

function [10:0] toward0;
	input [10:0] c;
	toward0 = c == 11'd0 ? c : c[10] ? c + 11'd1 : c - 11'd1;
endfunction

always @(posedge clk) begin
	upd_d <= ms_upd;
	t <= tick ? 17'd0 : t + 17'd1;
	if (reset) begin
		cx <= 11'd0;
		cy <= 11'd0;
	end
	else if (ms_upd != upd_d) begin
		cx <= sat(cx, ms_x);
		cy <= sat(cy, ms_y);
	end
	else if (tick) begin
		cx <= toward0(cx);
		cy <= toward0(cy);
	end
end

wire left = cx[10], right = !cx[10] && cx != 11'd0;
wire up = cy[10], down = !cy[10] && cy != 11'd0;
assign port = { 2'b11, ~ms_b[1], ~ms_b[0], ~up, ~down, ~right, ~left };

endmodule
