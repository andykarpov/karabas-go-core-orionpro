`timescale 1ns / 1ps
`default_nettype wire

/*
 orionpro_system.v

 The Orion-PRO: the processor, the memory dispatcher, the ports and the SRAM, on one clock of 40 MHz.
 docs/HARDWARE.md has the map; the order of the checks in the memory is that of peekb / pokeb of
 OriZEmu, the mode v3.20 there.

 SRAM (a byte address of 22 bits, orion_sram):
   000000  RAM, 2 MB: a page of 64 KB is {page[4:1], a[15:0], page[0]}, so pages 0 and 1 are the two
           byte lanes of one address (the video reads two planes in one access)
   200000  ROM disk, 256 KB (an FL item), read through port A of the PPI at 28 / F500
   240000  the disk images A and B (orion_fdd_cache), 820 KB each
   3E0000  ROM2, 64 KB (core.json or an FL item), 3F0000 ROM1, 8 KB
 The ROMs arrive by the ROM loader of the mcu: rom_addr is that byte address, the machine is in
 reset while rom_active.
*/

module orionpro_system #(
	parameter PHYS_FDD = 0       // the floppy connector of the Karabas Go (orion_fdd_phys)
) (
	input wire clk,
	input wire reset,
	input wire [1:0] boot,       // the DIP switches: 0 the menu of ROM1, 1 PRO, 2 Orion-128
	input wire [1:0] cpu_speed,  // 0 2.5, 1 5, 2 10 MHz; D5 of port 0A is 2.5 MHz
	input wire [1:0] ram_size,   // 0 512 KB, 1 1 MB, 2 2 MB
	input wire kb_ms7007,        // MS7007 keyboard (else RK-86), change it with a reset
	input wire [12:0] joy,       // the joysticks as keys (orion_kbd)

	// the ROM loader of the mcu
	input wire rom_active,
	input wire [21:0] rom_addr,
	input wire [7:0] rom_data,
	input wire rom_wr,

	// the file loader of the mcu, orion_loader; the machine is in reset meanwhile
	input wire file_active,
	input wire [7:0] file_slot,
	input wire [31:0] file_addr,
	input wire [7:0] file_data,
	input wire file_wr,

	// the file mounter of the mcu: the disks A and B are its slots 4 and 5, the hard disks 6 and 7
	input wire [7:0] img_mounted,
	input wire [63:0] img_size,
	input wire [7:0] img_wp,
	input wire img_data_wr,
	input wire [8:0] img_data_addr,
	input wire [7:0] img_data,
	input wire img_result_wr,
	input wire [7:0] img_result,
	input wire [15:0] img_sum,
	output wire img_q_wr,
	output wire [23:0] img_q_di,
	input wire img_q_ack,

	input wire [7:0] kb_scancode,
	input wire kb_scancode_upd,

	// the picture: 800 x 600 at 60 Hz on clk, or 720 x 576 at 50 Hz on clk_pix (pal, 27 MHz); hs / vs
	// active high (576p wants them low on the pins)
	input wire clk_pix,
	input wire pal,
	output wire [23:0] rgb,
	output wire hs,
	output wire vs,
	output wire de,

	output wire [7:0] rtc_a,
	output wire [7:0] rtc_di,
	input wire [7:0] rtc_do,
	output wire rtc_cs,
	output wire rtc_wr_n,

	output wire beep,
	output wire [9:0] ay_sound,
	// the physical floppy drives (PHYS_FDD): CMD_IMG_PHYS of the mcu, the pins of the Go
	input wire img_phys_wr,
	input wire [15:0] img_phys,
	input wire FDC_INDEX,
	output wire [1:0] FDC_DRIVE,
	output wire FDC_MOTOR,
	output wire FDC_DIR,
	output wire FDC_STEP,
	output wire FDC_WDATA,
	output wire FDC_WGATE,
	input wire FDC_TR00,
	input wire FDC_WPRT,
	input wire FDC_RDATA,
	output wire FDC_SIDE_N,
	input wire tape_in,          // the tape: port C of the keyboard PPI, D4 in (RK-86 keyboard only: MS7007 has a row there), D0 out
	output wire tape_out,

	output wire [20:0] MA,
	inout wire [15:0] MD,
	output wire [1:0] MWR_N
);

wire run_reset = reset | rom_active | file_active;

wire [15:0] a;
wire [7:0] cpu_do;
reg [7:0] cpu_di;
wire mem_rd, mem_wr, io_rd, io_wr, inta;
wire rd_ok;
wire phys_now, phys_drq, phys_hold;
wire [7:0] phys_do;
wire int_n;
wire [1:0] spd;

orion_cpu cpu (
	.clk(clk),
	.reset(run_reset),
	.speed(spd),
	.rd_ok(rd_ok),
	.hold(phys_hold),
	.addr(a),
	.dout(cpu_do),
	.din(cpu_di),
	.mem_rd(mem_rd),
	.mem_wr(mem_wr),
	.io_rd(io_rd),
	.io_wr(io_wr),
	.int_n(int_n),
	.inta(inta)
);

// ------------------------------------------------------------------ decoding
reg [7:0] p01 = 8'd0, p02 = 8'd0;  // the printer: latches only
reg [7:0] p04 = 8'd0, p05 = 8'd0, p06 = 8'd0;  // the segments of the windows RAM0..2
reg [7:0] p08 = 8'd0;         // the working page of PRO
reg [7:0] p09 = 8'd0;         // the segment of ROM2
reg [7:0] p0a = 8'h10;        // D0..2 the windows, D3 ROM2, D4 ROM1, D5 2.5 MHz, D6 F000 fixed, D7 Orion-128
wire o128 = p0a[7];
wire mem_any = mem_rd | mem_wr;
wire io_any = io_rd | io_wr;
wire [7:0] ioa = a[7:0];
wire sel_dev = o128 && mem_any && a[15:10] == 6'b111101;   // F400-F7FF
wire sel_f4 = (sel_dev && a[9:8] == 2'd0) || (io_any && ioa[7:2] == 6'b000110);  // 18-1B
wire sel_f5 = (sel_dev && a[9:8] == 2'd1) || (io_any && ioa[7:2] == 6'b001010);  // 28-2B
wire sel_f7 = sel_dev && a[9:8] == 2'd3;
wire wr_dev = mem_wr | io_wr;
wire rd_dev = mem_rd | io_rd;
wire sel_fdc, sel_rgu, fdc_drq;
wire sel_rtc_a = (sel_f7 && (a[7:0] == 8'h60 || a[7:0] == 8'hB1)) || (io_any && ioa == 8'h51);
wire sel_rtc_d = (sel_f7 && (a[7:0] == 8'h61 || a[7:0] == 8'hB0)) || (io_any && ioa == 8'h50);
reg [7:0] rtc_ar = 8'd0;
wire ay_fd = a[15] && ioa == 8'hFD;                        // FFFD (A14 = 1), BFFD (A14 = 0)
wire ay_sel_reg = io_any && ((ay_fd && a[14]) || ioa == 8'h3F);
wire ay_sel_data = io_any && ((ay_fd && !a[14]) || ioa == 8'h3E);
wire [7:0] ay_do;
wire sdc_busy, sdc_done, sdc_error, sdc_in_strobe;
wire [2:0] sdc_slot;
wire [8:0] sdc_byte_addr;
wire [7:0] sdc_in_data;
wire [7:0] fdc_do;
wire [7:0] sdc_img_mounted;
wire [1:0] hd_rd, hd_wr;
wire [63:0] sdc_img_size;

wire wr_any = mem_wr | io_wr;
reg wr_d = 1'b0;
always @(posedge clk)
	wr_d <= wr_any;
wire wr_p = wr_any & ~wr_d;   // one clock at the start of a write

// the latches: the ports of the Z80, and F800-FA00 in the memory in the mode Orion-128
wire mw = mem_wr && o128;
wire lat_f8 = (mw && a[15:8] == 8'hF8) || (io_wr && ioa == 8'hF8);
wire lat_f9 = (mw && a[15:8] == 8'hF9) || (io_wr && ioa == 8'hF9);
wire lat_fa = (mw && a[15:8] == 8'hFA) || (io_wr && ioa == 8'hFA);
wire lat_fb = io_wr && ioa == 8'hFB;
wire lat_fc = io_wr && ioa == 8'hFC;
wire lat_fe = io_wr && ioa == 8'hFE;
wire lat_ff = io_wr && ioa == 8'hFF;
wire lat_2c = io_wr && ioa == 8'h2C;

reg [7:0] vmode = 8'd0;       // port F8: D4..0 the mode, D7 screen of 480 points
reg [7:0] pfa = 8'd0;         // port FA: D1..0 the screen, D7 screen of 512 points
reg [7:0] pf9 = 8'd0;         // port F9: the working page of the mode Orion-128
reg [7:0] pfc = 8'd0;         // port FC: the colours of the pseudocolour mode
reg [1:0] rd_page = 2'd0;     // ports FE D1..0, 2C: the page of the ROM disk
reg snd_fe = 1'b0;            // FE D4
reg snd_ff = 1'b0;            // toggled by a write to port FF
// port FB: D7 = 0 the dispatcher of Orion-128: 0000-3FFF is the segment D1..0 of page D3..2;
// D6 interrupts, D5 all RAM
reg [7:0] fb = 8'h80;

always @(posedge clk) begin
	if (run_reset) begin
		vmode <= 8'd0;
		pfa <= 8'd0;
		pf9 <= 8'd0;
		pfc <= 8'd0;
		rd_page <= 2'd0;
		snd_fe <= 1'b0;
		snd_ff <= 1'b0;
		fb <= 8'h80;
		p01 <= 8'd0;
		p02 <= 8'd0;
		p04 <= 8'd0;
		p05 <= 8'd0;
		p06 <= 8'd0;
		p08 <= 8'd0;
		p09 <= 8'd0;
		p0a <= 8'h10;
	end
	else if (wr_p) begin
		if (lat_f8) vmode <= cpu_do;
		if (lat_f9) pf9 <= cpu_do;
		if (lat_fa) pfa <= cpu_do;
		if (lat_fb) fb <= cpu_do;
		if (lat_fc) pfc <= cpu_do;
		if (lat_fe) begin
			rd_page <= cpu_do[1:0];
			snd_fe <= cpu_do[4];
		end
		if (lat_2c) rd_page <= cpu_do[1:0];
		if (lat_ff) snd_ff <= ~snd_ff;
		if (io_wr) case (ioa)
			8'h01: p01 <= cpu_do;
			8'h02: p02 <= cpu_do;
			8'h04: p04 <= cpu_do;
			8'h05: p05 <= cpu_do;
			8'h06: p06 <= cpu_do;
			8'h08: p08 <= cpu_do;
			8'h09: p09 <= cpu_do;
			8'h0A: p0a <= cpu_do;
			default: ;
		endcase
	end
end

assign spd = p0a[5] ? 2'd0 : cpu_speed;

assign beep = snd_fe ^ snd_ff;

// the interrupt of the Z80 Card: 50 Hz, the line is held until the Z80 takes it or 64 states of
// 2.5 MHz later
reg [19:0] tick = 20'd0;
reg [10:0] int_hold = 11'd0;
always @(posedge clk) begin
	tick <= (tick == 20'd799999) ? 20'd0 : tick + 20'd1;
	if (run_reset || inta || !fb[6])
		int_hold <= 11'd0;
	else if (tick == 20'd0)
		int_hold <= 11'd1024;
	else if (int_hold != 11'd0)
		int_hold <= int_hold - 11'd1;
end
assign int_n = int_hold == 11'd0;

// ------------------------------------------------------------------ the PPIs
wire [7:0] ppi4_do, ppi5_do;
wire [7:0] rd_pb, rd_pc;
wire [7:0] sram_do;
wire [7:0] kb_scan, kb_ret;
wire [3:0] kb_pc;
wire [7:0] kb_pc_o;
reg [1:0] tape_s = 2'b11;
always @(posedge clk)
	tape_s <= { tape_s[0], tape_in };
assign tape_out = kb_pc_o[0];

orion_kbd kbd (
	.clk(clk), .reset(run_reset), .ms7007(kb_ms7007), .joy(joy), .scancode(kb_scancode), .scancode_upd(kb_scancode_upd),
	.scan(kb_scan), .ret(kb_ret), .pc_hi(kb_pc)
);

orion_ppi ppi_kbd (
	.clk(clk), .reset(run_reset), .a(a[1:0]), .wr(wr_p & wr_dev & sel_f4), .din(cpu_do), .dout(ppi4_do),
	.pa_i(8'hFF), .pb_i(kb_ret), .pc_i({kb_pc[3:1], (kb_ms7007 ? kb_pc[0] : tape_s[1]), 4'hF}),
	.pa_in(), .pa_o(kb_scan), .pb_o(), .pc_o(kb_pc_o)
);

// the ROM disk: B and C are the address, A the byte
orion_ppi ppi_rd (
	.clk(clk), .reset(run_reset), .a(a[1:0]), .wr(wr_p & wr_dev & sel_f5), .din(cpu_do), .dout(ppi5_do),
	.pa_i(sram_do), .pb_i(8'hFF), .pc_i(8'hFF),
	.pa_in(), .pa_o(), .pb_o(rd_pb), .pc_o(rd_pc)
);

// ------------------------------------------------------------------ the memory
wire [7:0] work = o128 ? pf9 : p08;
wire [5:0] page_mask = ram_size == 2'd0 ? 6'b000111 : ram_size == 2'd1 ? 6'b001111 : 6'b011111;
wire low = a[15:14] == 2'b00;
wire d16 = o128 && !fb[7] && low;              // the dispatcher of Orion-128
wire win_on = low ? p0a[0] : a[15:14] == 2'b01 ? p0a[1] : a[15:14] == 2'b10 ? p0a[2] : 1'b0;
wire [7:0] win_seg = low ? p04 : a[14] ? p05 : p06;
wire fix_f = a[15:12] == 4'hF && (o128 ? !fb[5] : p0a[6]);   // segment 31
wire [5:0] page = (d16 ? { 4'd0, fb[3:2] } : win_on ? win_seg[7:2] : fix_f ? 6'd7 : work[5:0]) & page_mask;
wire [15:0] ram_a = d16 ? { fb[1:0], a[13:0] } : win_on ? { win_seg[1:0], a[13:0] } : a;
wire [21:0] ram_addr = { 1'b0, page[4:1], ram_a, page[0] };

wire sel_rom1 = a[15:13] == 3'b000 && p0a[4];
wire sel_rom2 = a[15:13] == 3'b001 && p0a[3];
wire sel_rd = sel_f5 && a[1:0] == 2'd0;

wire [21:0] sram_addr = sel_rd ? { 4'b1000, rd_page, rd_pc, rd_pb } :
                        sel_rom1 ? { 9'b111111000, a[12:0] } :
                        sel_rom2 ? { 6'b111110, p09[2:0], a[12:0] } :
                        ram_addr;
// the area of the ports of Orion-128 is never written: F400-F7FF are the ports, F800-FFFF only latches
wire sram_we = mem_wr && !sel_rom1 && !sel_rom2 && !(o128 && a[15:10] >= 6'b111101);

wire [7:0] dip = { boot == 2'd2, 1'b0, boot != 2'd0, 2'b00, ~kb_ms7007, 2'b11 };

always @* begin
	cpu_di = 8'hFF;
	if (inta && !mem_rd)      // the T80 shows M1 and IORQ together for a moment after reset
		cpu_di = 8'hFF;
	else if (rd_dev && sel_f4)
		cpu_di = ppi4_do;
	else if (rd_dev && sel_f5)
		cpu_di = ppi5_do;
	else if (rd_dev && sel_rtc_a)
		cpu_di = rtc_ar;
	else if (rd_dev && sel_rtc_d)
		cpu_di = rtc_do;
	else if (rd_dev && sel_fdc)
		cpu_di = phys_now ? phys_do : fdc_do;
	else if (rd_dev && sel_rgu)
		cpu_di = { 6'd0, phys_now ? phys_drq : fdc_drq, 1'b0 };
	else if (mem_rd) begin
		if (!sel_dev) cpu_di = sram_do;
	end
	else if (io_rd) case (ioa)
		8'h00: cpu_di = dip;
		8'h01: cpu_di = p01;
		8'h02: cpu_di = p02;
		8'h04: cpu_di = p04;
		8'h05: cpu_di = p05;
		8'h06: cpu_di = p06;
		8'h08: cpu_di = p08;
		8'h09: cpu_di = p09;
		8'h0A: cpu_di = p0a;
		8'hFB: cpu_di = fb;
		default: if (ay_sel_reg) cpu_di = ay_do;
	endcase
end

// ------------------------------------------------------------------ the clock
// the registers of the mcu (kg_mcu_rtc): a write is a clock long
always @(posedge clk)
	if (wr_p && wr_dev && sel_rtc_a)
		rtc_ar <= cpu_do;
assign rtc_a = rtc_ar;
assign rtc_di = cpu_do;
assign rtc_cs = wr_p && wr_dev && sel_rtc_d;
assign rtc_wr_n = !rtc_cs;

// ------------------------------------------------------------------ AY
// 1.75 MHz: 3.5 MHz of 40 (+7 of 80) divided by jt49
reg [6:0] ay_acc = 7'd0;
reg ay_ce = 1'b0;
always @(posedge clk) begin
	ay_ce <= ay_acc >= 7'd73;
	ay_acc <= (ay_acc >= 7'd73) ? ay_acc + 7'd7 - 7'd80 : ay_acc + 7'd7;
end

reg [3:0] ay_reg = 4'd0;
wire ay_wr_reg = wr_p && ay_sel_reg;
wire ay_wr_data = wr_p && ay_sel_data;
always @(posedge clk)
	if (run_reset)
		ay_reg <= 4'd0;
	else if (ay_wr_reg)
		ay_reg <= cpu_do[3:0];

jt49 ay (
	.rst_n(~run_reset),
	.clk(clk),
	.clk_en(ay_ce),
	.addr(ay_reg),
	.cs_n(1'b0),
	.wr_n(~ay_wr_data),
	.din(cpu_do),
	.sel(1'b0),
	.dout(ay_do),
	.sound(ay_sound),
	.A(),
	.B(),
	.C(),
	.sample(),
	.IOA_in(8'hFF),
	.IOA_out(),
	.IOB_in(8'hFF),
	.IOB_out()
);

// ------------------------------------------------------------------ the hard disks
// docs/PLAN.md Ф2: the IDE at 56-5F
wire [31:0] hd_sector = 32'd0;
wire [7:0] hd_byte_out = 8'hFF;
wire sdc_hd = sdc_slot[2:1] == 2'b11;
assign hd_rd = 2'b00;
assign hd_wr = 2'b00;

// ------------------------------------------------------------------ the disk drive
// KR1818VG93 at 10-13 and, in the mode Orion-128, F700-F703, F710-F713 (an incomplete decoder), the
// control register at 14, F704, F714, F720: D0 the drive, D4 the side, inverted. Read, the control
// register shows DRQ in D1. F708, F718 is the same register of the controller by M. Korotkin: D0 the
// side, D1 the drive (DSDOS writes there when F704 does not read FF).
assign sel_fdc = (sel_f7 && a[7:5] == 3'd0 && a[3:2] == 2'd0) || (io_any && ioa[7:2] == 6'b000100);
assign sel_rgu = (sel_f7 && (a[7:0] == 8'h20 || (a[7:5] == 3'd0 && a[3:0] == 4'd4))) || (io_any && ioa == 8'h14);
wire sel_rgk = sel_f7 && a[7:5] == 3'd0 && a[3:0] == 4'd8;

reg [7:0] rgu = 8'd0;
always @(posedge clk)
	if (run_reset)
		rgu <= 8'd0;
	else if (wr_p && wr_dev && sel_rgu)
		rgu <= cpu_do;
	else if (wr_p && mem_wr && sel_rgk)
		rgu <= { 3'd0, ~cpu_do[0], 3'd0, cpu_do[1] };

// 5 MHz: a read of the Z80 at 10 MHz lasts 250 ns
reg [2:0] fdc_div = 3'd0;
always @(posedge clk)
	fdc_div <= fdc_div + 3'd1;

wire drive = rgu[0];

// the physical drives: map_a / map_b 0 the image, 1 DS0, 2 DS1 (CMD_IMG_PHYS slot 4 / 5); a mount of an
// image puts the drive back on it
reg [1:0] map_a = 2'd0, map_b = 2'd0;
always @(posedge clk) begin
	if (sdc_img_mounted[4]) map_a <= 2'd0;
	if (sdc_img_mounted[5]) map_b <= 2'd0;
	if (PHYS_FDD && img_phys_wr && img_phys[15:8] == 8'd4) map_a <= img_phys[1:0];
	if (PHYS_FDD && img_phys_wr && img_phys[15:8] == 8'd5) map_b <= img_phys[1:0];
end
wire [1:0] phys_ds = drive ? map_b : map_a;
assign phys_now = PHYS_FDD && phys_ds != 2'd0;

generate
	if (PHYS_FDD) begin : g_phys
		orion_fdd_phys phys (
			.clk(clk), .reset(run_reset),
			.sel(sel_fdc & phys_now), .a(a[1:0]), .rd(rd_dev), .wr(wr_dev), .din(cpu_do),
			.dout(phys_do), .drq(phys_drq), .hold(phys_hold), .ds(phys_ds), .side(~rgu[4]),
			.FDC_INDEX(FDC_INDEX), .FDC_DRIVE(FDC_DRIVE), .FDC_MOTOR(FDC_MOTOR), .FDC_DIR(FDC_DIR),
			.FDC_STEP(FDC_STEP), .FDC_WDATA(FDC_WDATA), .FDC_WGATE(FDC_WGATE), .FDC_TR00(FDC_TR00),
			.FDC_WPRT(FDC_WPRT), .FDC_RDATA(FDC_RDATA), .FDC_SIDE_N(FDC_SIDE_N)
		);
	end
	else begin : g_nophys
		assign phys_do = 8'hFF;
		assign phys_drq = 1'b0;
		assign phys_hold = 1'b0;
		assign FDC_DRIVE = 2'b00;
		assign FDC_MOTOR = 1'b0;
		assign FDC_DIR = 1'b0;
		assign FDC_STEP = 1'b0;
		assign FDC_WDATA = 1'b0;
		assign FDC_WGATE = 1'b0;
		assign FDC_SIDE_N = 1'b0;
	end
endgenerate
reg disk_a = 1'b0, disk_b = 1'b0;
always @(posedge clk) begin
	if (sdc_img_mounted[4]) disk_a <= |sdc_img_size[31:0];
	if (sdc_img_mounted[5]) disk_b <= |sdc_img_size[31:0];
end

wire [31:0] sd_lba;
wire sd_rd, sd_wr, sd_ack_a, sd_ack_b, sd_wr_a, sd_wr_b;
wire [8:0] sd_addr_a, sd_addr_b;
wire [7:0] sd_do_a, sd_do_b, sd_buff_din;

wd1793 #(.RWMODE(1), .EDSK(0)) fdc (
	.clk_sys(clk),
	.ce(fdc_div == 3'd0),
	.reset(run_reset),
	.io_en(sel_fdc & ~phys_now),
	.rd(rd_dev),
	.wr(wr_dev),
	.addr(a[1:0]),
	.din(cpu_do),
	.dout(fdc_do),
	.drq(fdc_drq),
	.intrq(),
	.busy(),
	.wp(drive ? img_wp[5] : img_wp[4]),
	.size_code(3'd3),         // 5 sectors of 1024 bytes
	.layout(1'b0),            // track, side, sector
	.side(~rgu[4]),
	.ready(drive ? disk_b : disk_a),
	.img_mounted(sdc_img_mounted[4] | sdc_img_mounted[5]),
	.img_size(sdc_img_size[19:0]),
	.prepare(),
	.sd_lba(sd_lba),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack_a | sd_ack_b),
	.sd_buff_addr(drive ? sd_addr_b : sd_addr_a),
	.sd_buff_dout(drive ? sd_do_b : sd_do_a),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_wr_a | sd_wr_b),
	.input_active(1'b0),
	.input_addr(20'd0),
	.input_data(8'd0),
	.input_wr(1'b0),
	.buff_addr(),
	.buff_read(),
	.buff_din(8'd0)
);

wire aux_req, aux_we, aux_ack;
wire [21:0] aux_addr;
wire [7:0] aux_din, aux_dout;

wire [7:0] sdc_byte_out_a, sdc_byte_out_b;
wire [31:0] sdc_sector_a, sdc_sector_b;
wire sdc_rd_a, sdc_wr_a, sdc_rd_b, sdc_wr_b;

// no reset: a reset of the machine during a request leaves img_sdc to finish it
img_sdc #(
	.OUT_LATENCY(3),
	.TIMEOUT(24'd8000000)     // 200 ms at 40 MHz
) sdc (
	.clk(clk),
	.reset(1'b0),
	.img_mounted(img_mounted),
	.img_size(img_size),
	.img_data_wr(img_data_wr),
	.img_data_addr(img_data_addr),
	.img_data(img_data),
	.img_result_wr(img_result_wr),
	.img_result(img_result),
	.img_sum(img_sum),
	.img_q_wr(img_q_wr),
	.img_q_di(img_q_di),
	.img_q_ack(img_q_ack),
	.sdc_img_mounted(sdc_img_mounted),
	.sdc_img_size(sdc_img_size),
	.sdc_rd({ hd_rd, sdc_rd_b, sdc_rd_a, 4'd0 }),
	.sdc_wr({ hd_wr, sdc_wr_b, sdc_wr_a, 4'd0 }),
	.sdc_sector((sdc_rd_a || sdc_wr_a) ? sdc_sector_a : (sdc_rd_b || sdc_wr_b) ? sdc_sector_b : hd_sector),
	.sdc_busy(sdc_busy),
	.sdc_done(sdc_done),
	.sdc_error(sdc_error),
	.sdc_slot(sdc_slot),
	.sdc_byte_in_strobe(sdc_in_strobe),
	.sdc_byte_addr(sdc_byte_addr),
	.sdc_byte_in_data(sdc_in_data),
	.sdc_byte_out_data(sdc_hd ? hd_byte_out :
		sdc_slot == 3'd5 ? sdc_byte_out_b : sdc_byte_out_a),
	.active()
);

wire fd_req_a, fd_we_a, fd_req_b, fd_we_b, ld_req, ld_we;
wire [21:0] fd_addr_a, fd_addr_b, ld_addr;
wire [7:0] fd_din_a, fd_din_b, ld_din;
reg [1:0] own = 2'd0;         // the aux port: 1 loader, 2 disk A, 3 disk B
wire loading = rom_active | file_active;

orion_fdd_cache #(.BASE(22'h240000), .SLOT(3'd4)) cache_a (
	.clk(clk),
	.img_mounted(sdc_img_mounted[4]),
	.img_size(sdc_img_size[31:0]),
	.sd_rd(sd_rd & ~drive),
	.sd_wr(sd_wr & ~drive),
	.sd_lba(sd_lba),
	.sd_ack(sd_ack_a),
	.sd_buff_addr(sd_addr_a),
	.sd_buff_dout(sd_do_a),
	.sd_buff_wr(sd_wr_a),
	.sd_buff_din(sd_buff_din),
	.sdc_rd(sdc_rd_a),
	.sdc_wr(sdc_wr_a),
	.sdc_sector(sdc_sector_a),
	.sdc_busy(sdc_busy),
	.sdc_done(sdc_done),
	.sdc_error(sdc_error),
	.sdc_slot(sdc_slot),
	.sdc_byte_in_strobe(sdc_in_strobe),
	.sdc_byte_addr(sdc_byte_addr),
	.sdc_byte_in_data(sdc_in_data),
	.sdc_byte_out_data(sdc_byte_out_a),
	.pause(loading),
	.aux_req(fd_req_a),
	.aux_we(fd_we_a),
	.aux_addr(fd_addr_a),
	.aux_din(fd_din_a),
	.aux_ack(aux_ack && own == 2'd2),
	.aux_dout(aux_dout),
	.filling(),
	.filled()
);

orion_fdd_cache #(.BASE(22'h30D000), .SLOT(3'd5)) cache_b (
	.clk(clk),
	.img_mounted(sdc_img_mounted[5]),
	.img_size(sdc_img_size[31:0]),
	.sd_rd(sd_rd & drive),
	.sd_wr(sd_wr & drive),
	.sd_lba(sd_lba),
	.sd_ack(sd_ack_b),
	.sd_buff_addr(sd_addr_b),
	.sd_buff_dout(sd_do_b),
	.sd_buff_wr(sd_wr_b),
	.sd_buff_din(sd_buff_din),
	.sdc_rd(sdc_rd_b),
	.sdc_wr(sdc_wr_b),
	.sdc_sector(sdc_sector_b),
	.sdc_busy(sdc_busy),
	.sdc_done(sdc_done),
	.sdc_error(sdc_error),
	.sdc_slot(sdc_slot),
	.sdc_byte_in_strobe(sdc_in_strobe),
	.sdc_byte_addr(sdc_byte_addr),
	.sdc_byte_in_data(sdc_in_data),
	.sdc_byte_out_data(sdc_byte_out_b),
	.pause(loading),
	.aux_req(fd_req_b),
	.aux_we(fd_we_b),
	.aux_addr(fd_addr_b),
	.aux_din(fd_din_b),
	.aux_ack(aux_ack && own == 2'd3),
	.aux_dout(aux_dout),
	.filling(),
	.filled()
);

// a master holds its request until the ack and drops it at that edge
always @(posedge clk) begin
	if (aux_ack)
		own <= 2'd0;
	else if (own == 2'd0)
		own <= ld_req ? 2'd1 : fd_req_a ? 2'd2 : fd_req_b ? 2'd3 : 2'd0;
end
assign aux_req = own == 2'd1 ? ld_req : own == 2'd2 ? fd_req_a : own == 2'd3 ? fd_req_b : 1'b0;
assign aux_we = own == 2'd1 ? ld_we : own == 2'd2 ? fd_we_a : fd_we_b;
assign aux_addr = own == 2'd1 ? ld_addr : own == 2'd2 ? fd_addr_a : fd_addr_b;
assign aux_din = own == 2'd1 ? ld_din : own == 2'd2 ? fd_din_a : fd_din_b;

orion_loader loader (
	.clk(clk),
	.rom_active(rom_active),
	.rom_addr(rom_addr),
	.rom_data(rom_data),
	.rom_wr(rom_wr),
	.file_active(file_active),
	.file_slot(file_slot),
	.file_addr(file_addr),
	.file_data(file_data),
	.file_wr(file_wr),
	.tick(tick == 20'd0),
	.aux_req(ld_req),
	.aux_we(ld_we),
	.aux_addr(ld_addr),
	.aux_din(ld_din),
	.aux_ack(aux_ack && own == 2'd1),
	.aux_dout(aux_dout)
);

wire vid_req, vid_valid;
// the palette of the Multicard, ports E0..E2 (orion_pal in each video)
wire [2:0] pal_we = (wr_p && io_wr && ioa[7:2] == 6'b111000) ? (ioa[1:0] == 2'd0 ? 3'b001 : ioa[1:0] == 2'd1 ? 3'b010 : ioa[1:0] == 2'd2 ? 3'b100 : 3'b000) : 3'b000;
wire [20:0] vid_addr;
wire [15:0] vid_dout;

wire v6_req, v5_req;
wire [20:0] v6_addr, v5_addr;
wire [23:0] v6_rgb, v5_rgb;
wire v6_hs, v6_vs, v6_de, v5_hs, v5_vs, v5_de;

orion_video video (
	.clk(clk),
	.vmode(vmode[4:0]),
	.vpage(pfa[1:0]),
	.w512(pfa[7]),
	.w480(vmode[7]),
	.pcolor(pfc),
	.pal_we(pal_we),
	.pal_d(cpu_do),
	.vid_req(v6_req),
	.vid_addr(v6_addr),
	.vid_dout(vid_dout),
	.vid_valid(vid_valid & ~pal),
	.rgb(v6_rgb),
	.hs(v6_hs),
	.vs(v6_vs),
	.de(v6_de)
);

orion_video_576 video576 (
	.clk(clk),
	.clk_pix(clk_pix),
	.en(pal),
	.vmode(vmode[4:0]),
	.vpage(pfa[1:0]),
	.w512(pfa[7]),
	.w480(vmode[7]),
	.pcolor(pfc),
	.pal_we(pal_we),
	.pal_d(cpu_do),
	.vid_req(v5_req),
	.vid_addr(v5_addr),
	.vid_dout(vid_dout),
	.vid_valid(vid_valid & pal),
	.rgb(v5_rgb),
	.hs(v5_hs),
	.vs(v5_vs),
	.de(v5_de)
);

// one of them reads the SRAM; the other one runs on and its requests are dropped
assign vid_req = pal ? v5_req : v6_req;
assign vid_addr = pal ? v5_addr : v6_addr;
assign rgb = pal ? v5_rgb : v6_rgb;
assign hs = pal ? v5_hs : v6_hs;
assign vs = pal ? v5_vs : v6_vs;
assign de = pal ? v5_de : v6_de;

orion_sram sram (
	.clk(clk),
	.addr(sram_addr),
	.we(sram_we),
	.din(cpu_do),
	.dout(sram_do),
	.rd_ok(rd_ok),
	.aux_req(aux_req),
	.aux_we(aux_we),
	.aux_addr(aux_addr),
	.aux_din(aux_din),
	.aux_ack(aux_ack),
	.aux_dout(aux_dout),
	.vid_req(vid_req),
	.vid_addr(vid_addr),
	.vid_dout(vid_dout),
	.vid_valid(vid_valid),
	.MA(MA),
	.MD(MD),
	.MWR_N(MWR_N)
);

endmodule
