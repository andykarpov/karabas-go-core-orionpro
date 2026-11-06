`timescale 1ns / 1ps
`default_nettype wire

/*
 orion_ppi.v

 KR580VV55 (i8255) in mode 0, all the Orion uses: three ports, each an input or a latch by the
 control word. A port set as input shows pX_i and drives FF on pX_o (the pull-ups of the bus);
 pa_in tells that port A is an input (the IDE lines of orion_ide are idle then). A
 control word with D7 = 1 sets the directions and clears the latches, D7 = 0 sets or clears a bit
 of port C. After reset all ports are inputs (control word 9B). wr is a pulse of one clock.
*/

module orion_ppi (
	input wire clk,
	input wire reset,
	input wire [1:0] a,
	input wire wr,
	input wire [7:0] din,
	output reg [7:0] dout,
	input wire [7:0] pa_i,
	input wire [7:0] pb_i,
	input wire [7:0] pc_i,
	output wire pa_in,
	output wire [7:0] pa_o,
	output wire [7:0] pb_o,
	output wire [7:0] pc_o
);

reg in_a = 1'b1, in_b = 1'b1, in_ch = 1'b1, in_cl = 1'b1;
reg [7:0] la = 8'd0, lb = 8'd0, lc = 8'd0;

always @(posedge clk) begin
	if (reset) begin
		{in_a, in_b, in_ch, in_cl} <= 4'b1111;
		la <= 8'd0;
		lb <= 8'd0;
		lc <= 8'd0;
	end
	else if (wr) begin
		case (a)
			2'd0: la <= din;
			2'd1: lb <= din;
			2'd2: lc <= din;
			2'd3:
				if (din[7]) begin
					in_a <= din[4];
					in_ch <= din[3];
					in_b <= din[1];
					in_cl <= din[0];
					la <= 8'd0;
					lb <= 8'd0;
					lc <= 8'd0;
				end
				else
					lc[din[3:1]] <= din[0];
		endcase
	end
end

assign pa_in = in_a;
assign pa_o = in_a ? 8'hFF : la;
assign pb_o = in_b ? 8'hFF : lb;
assign pc_o = { in_ch ? 4'hF : lc[7:4], in_cl ? 4'hF : lc[3:0] };

always @* begin
	case (a)
		2'd0: dout = in_a ? pa_i : la;
		2'd1: dout = in_b ? pb_i : lb;
		2'd2: dout = { in_ch ? pc_i[7:4] : lc[7:4], in_cl ? pc_i[3:0] : lc[3:0] };
		default: dout = 8'hFF;
	endcase
end

endmodule
