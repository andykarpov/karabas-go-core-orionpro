`timescale 1ns / 1ps
`default_nettype wire

// orionpro_system with a model of the SRAM (two lanes of 2M x 8, /OE low, as msx tb_sys), for sim_boot.
module tb_boot (
	input wire clk,
	input wire reset,
	input wire [1:0] boot,
	input wire [1:0] cpu_speed,
	input wire [1:0] ram_size,
	input wire kb_ms7007,
	input wire file_active,
	input wire [7:0] file_slot,
	input wire [31:0] file_addr,
	input wire [7:0] file_data,
	input wire file_wr,
	input wire [7:0] img_mounted,
	input wire [63:0] img_size,
	input wire img_data_wr,
	input wire [8:0] img_data_addr,
	input wire [7:0] img_data,
	input wire img_result_wr,
	input wire [7:0] img_result,
	input wire [15:0] img_sum,
	output wire img_q_wr,
	output wire [23:0] img_q_di,
	input wire img_q_ack,
	input wire rom_active,
	input wire [21:0] rom_addr,
	input wire [7:0] rom_data,
	input wire rom_wr,
	input wire [7:0] kb_scancode,
	input wire kb_scancode_upd,
	output wire [23:0] rgb,
	output wire hs,
	output wire vs,
	output wire de,
	output wire beep,
	input wire [21:0] dbg_addr,
	output wire [7:0] dbg_q
);

wire [20:0] MA;
wire [15:0] MD;
wire [1:0] MWR_N;

orionpro_system sys (
	.clk(clk), .reset(reset), .boot(boot), .cpu_speed(cpu_speed), .ram_size(ram_size), .kb_ms7007(kb_ms7007),
	.rom_active(rom_active), .rom_addr(rom_addr), .rom_data(rom_data), .rom_wr(rom_wr),
	.file_active(file_active), .file_slot(file_slot), .file_addr(file_addr), .file_data(file_data), .file_wr(file_wr),
	.img_mounted(img_mounted), .img_size(img_size), .img_wp(8'd0), .img_data_wr(img_data_wr),
	.img_data_addr(img_data_addr), .img_data(img_data), .img_result_wr(img_result_wr), .img_result(img_result),
	.img_sum(img_sum), .img_q_wr(img_q_wr), .img_q_di(img_q_di), .img_q_ack(img_q_ack),
	.kb_scancode(kb_scancode), .kb_scancode_upd(kb_scancode_upd),
	.joy(13'd0), .img_phys_wr(1'b0), .img_phys(16'd0), .FDC_INDEX(1'b0), .FDC_TR00(1'b0), .FDC_WPRT(1'b0), .FDC_RDATA(1'b0), .rtc_a(), .rtc_di(), .rtc_do(8'h00), .rtc_cs(), .rtc_wr_n(),
	.clk_pix(clk), .pal(1'b0), .rgb(rgb), .hs(hs), .vs(vs), .de(de), .beep(beep), .ay_sound(), .tape_in(1'b1), .tape_out(),
	.MA(MA), .MD(MD), .MWR_N(MWR_N)
);

reg [7:0] lo [0:2097151];
reg [7:0] hi [0:2097151];
assign MD = (MWR_N == 2'b11) ? { hi[MA], lo[MA] } : 16'bz;
assign dbg_q = dbg_addr[0] ? hi[dbg_addr[21:1]] : lo[dbg_addr[21:1]];

always @(posedge clk) begin
	if (!MWR_N[0]) lo[MA] <= MD[7:0];
	if (!MWR_N[1]) hi[MA] <= MD[15:8];
end

// +bus: the first memory and port accesses of the CPU
reg bus_log = 1'b0;
initial bus_log = $test$plusargs("bus");
integer bus_n = 0;
reg bus_d = 1'b0;
always @(posedge clk) begin
	bus_d <= sys.mem_rd | sys.mem_wr | sys.io_rd | sys.io_wr | sys.inta;
	if (bus_log && bus_n < 400 && (sys.mem_rd | sys.mem_wr | sys.io_rd | sys.io_wr | sys.inta) && !bus_d) begin
		bus_n = bus_n + 1;
		$display("%s %04x di %02x do %02x ih %0d", sys.inta ? "ia" : sys.mem_rd ? "mr" : sys.mem_wr ? "mw" : sys.io_rd ? "ir" : "iw", sys.a, sys.cpu_di, sys.cpu_do, sys.int_hold);
	end
end
endmodule
