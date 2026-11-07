`timescale 1ns/1ps
module tb;
reg clk = 0; always #1 clk = ~clk;
reg [7:0] x = 0, y = 0; reg [2:0] b = 0; reg upd = 0;
wire [7:0] p;
orion_mouse #(.STEP(10)) m (.clk(clk), .reset(1'b0), .ms_x(x), .ms_y(y), .ms_b(b), .ms_upd(upd), .port(p));
integer err = 0;
task chk(input [7:0] e, input [8*20:1] s); if (p !== e) begin $display("FAIL %0s: %h want %h", s, p, e); err = err + 1; end endtask
task rep(input [7:0] dx, input [7:0] dy, input [2:0] bb); begin @(negedge clk); x = dx; y = dy; b = bb; upd = ~upd; @(negedge clk); @(negedge clk); end endtask
initial begin
	#4 chk(8'hFF, "idle");
	rep(8'd3, 8'hFE, 3'b001);          // right 3, up 2, left button
	chk(8'b11_10_0_1_0_1, "right up lmb");
	#40 chk(8'b11_10_1_1_0_1, "up done");     // y 2 units = 20 clocks of STEP 10 (each unit 10 cycles of 2 ns)
	#30 chk(8'b11_10_1_1_1_1, "x done");
	rep(8'h80, 8'd0, 3'b010);          // left 128, right button
	chk(8'b11_01_1_1_1_0, "left rmb");
	rep(8'h7F, 8'd5, 3'b000);          // +127: count -1 ... still left
	chk(8'b11_11_1_0_1_0, "left down");
	#2000 chk(8'hFF, "all done");
	if (err == 0) $display("PASS"); $finish;
end
endmodule
