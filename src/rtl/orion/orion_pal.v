`timescale 1ns / 1ps
`default_nettype wire

/*
 orion_pal.v

 The palette of the Multicard: 16 colours of 4 bits per channel, written by the ports E0 (red), E1
 (green), E2 (blue) as a byte { index, level }. The index is { G, R, B, I }. It starts with the
 table PALTAB of ROM1, which is also what the BIOS writes. Read asynchronously: rare writes, the
 output is registered by the video.
*/

module orion_pal (
	input wire clk,
	input wire [2:0] we,       // D0 red, D1 green, D2 blue
	input wire [7:0] din,
	input wire [3:0] idx,
	output wire [23:0] rgb
);

reg [3:0] r [0:15];
reg [3:0] g [0:15];
reg [3:0] b [0:15];

integer i;
initial begin
	for (i = 0; i < 16; i = i + 1) begin
		r[i] = (i & 4) ? ((i & 1) ? 4'hF : 4'hC) : (i == 1 ? 4'h4 : 4'h0);
		g[i] = (i & 8) ? ((i & 1) ? 4'hF : 4'hC) : (i == 1 ? 4'h4 : 4'h0);
		b[i] = (i & 2) ? ((i & 1) ? 4'hF : 4'hC) : (i == 1 ? 4'h4 : 4'h0);
	end
end

always @(posedge clk) begin
	if (we[0]) r[din[7:4]] <= din[3:0];
	if (we[1]) g[din[7:4]] <= din[3:0];
	if (we[2]) b[din[7:4]] <= din[3:0];
end

wire [3:0] lr = r[idx], lg = g[idx], lb = b[idx];
assign rgb = { lr, lr, lg, lg, lb, lb };

endmodule
