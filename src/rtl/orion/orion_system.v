`timescale 1ns / 1ps
`default_nettype wire

/*
 orion_system.v

 The Orion-128: the processor, the memory map, the ports and the SRAM, on one clock of 40 MHz.
 docs/HARDWARE.md has the map.

 SRAM (a byte address of 22 bits, orion_sram):
   000000  RAM, 1 MB: a page of 64 KB is {page[3:1], a[15:0], page[0]}, so pages 0 and 1 are the two
           byte lanes of one address (the video reads pixel and colour in one access)
   100000  ROM disk, 1 MB (the roms of core.json or an FL item), read through port A of the PPI at
           F500, 16 pages of 64 KB by port FE
   200000  Monitor (2 KB)
   240000  the disk images A and B (orion_fdd_cache), 820 KB each
 Orion-2010 (always on, it takes no addresses of the Z80 Card): F762 / F763 the SD card (orion_sd,
 on the image of HDD master), F764 / F765 a UART (a stub), F766 D6 the keyboard interrupt (vector
 FB), F767 the system register (D6..5 turbo, D4..3 page of the ROM disk, D2..0 p4f: D0 no window of
 the ports, D1 no ROM, D2 writes under the ROM; p4f only by OUT), F768 / F769 the scancode and its
 prefix, F76A an 8-bit DAC; IN / OUT 10-1F, 20-2F, 40-4F are F4xx, F5xx, F76x.
 Hard disks: orion_ide on the PPIs F500 and F600. Clock: F760 address, F761 data, or F7B1 address,
 F7B0 data, in the registers of the mcu. AY: ports FFFD, BFFD of the Z80, or F7A1 register number
 and read, F7A0 write.
 The ROMs arrive by the ROM loader of the mcu: rom_addr is that byte address, the machine is in
 reset while rom_active.

 After reset the Monitor answers everywhere (a read), until the first read at F800-FFFF: this is
 how a CPU that starts at 0000 finds its code at F800.
*/

module orion_system #(
	parameter PHYS_FDD = 0       // the floppy connector of the Karabas Go (orion_fdd_phys)
) (
	input wire clk,
	input wire reset,
	input wire cpu_z80,          // a change is a short reset
	input wire [1:0] cpu_speed,  // the Z80: 0 2.5, 1 5, 2 10 MHz
	input wire [1:0] ram_size,   // 0 256, 1 512 KB, 2 1 MB
	input wire kb_ms7007,        // MS7007 keyboard (else RK-86), change it with a reset
	input wire mon_hi,           // the second 2 KB of a Monitor file of 4 KB; a change resets the machine
	// the UART of the Orion-2010 (F764 / F765) through kg_mcu_uart
	input wire [7:0] uart_rx_data,
	input wire [7:0] uart_rx_idx,
	output wire [7:0] uart_tx_data,
	output wire uart_tx_wr,
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
	output wire [7:0] dac,

	output wire [20:0] MA,
	inout wire [15:0] MD,
	output wire [1:0] MWR_N
);

// a change of the processor resets the machine for 16 states, the new one starts from the Monitor
reg z80 = 1'b0;
reg mhi = 1'b0;
reg [7:0] sw_cnt = 8'd0;
always @(posedge clk) begin
	if (sw_cnt != 8'd0)
		sw_cnt <= sw_cnt - 8'd1;
	else if (cpu_z80 != z80 || mon_hi != mhi) begin
		z80 <= cpu_z80;
		mhi <= mon_hi;
		sw_cnt <= 8'd255;
	end
end

wire run_reset = reset | rom_active | file_active | (sw_cnt != 8'd0);

// the speed of the Z80: the OSD item, or F767 D6..5 of the Orion-2010 (10 2.5, 00 5, 01 10 MHz)
reg [1:0] spd = 2'd0;
reg [1:0] spd_osd = 2'd0;
wire [1:0] p767_turbo = spd == 2'd0 ? 2'b10 : spd == 2'd1 ? 2'b00 : 2'b01;

wire [15:0] a;
wire [7:0] cpu_do;
reg [7:0] cpu_di;
wire mem_rd, mem_wr, io_rd, io_wr, inte, inta;
wire rd_ok;
wire phys_now, phys_drq, phys_hold;
wire [7:0] phys_do;
wire int_n;

orion_cpu cpu (
	.clk(clk),
	.reset(run_reset),
	.cpu_z80(z80),
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
	.inta(inta),
	.inte(inte)
);

// ------------------------------------------------------------------ decoding
wire full = z80 & fb[5];                       // Z80 Card: all of 0000-FFFF is RAM
wire top_f800 = !full && a[15:11] == 5'b11111;
reg [7:0] p767 = 8'd0;                         // F767 of the Orion-2010
wire win = !full && !p767[0];                  // the window of the ports in the memory
wire sel_dev = win && a[15:10] == 6'b111101;   // F400-F7FF, a memory access
// the IN / OUT mirrors of the Orion-2010: 10-1F F4xx, 20-2F F5xx, 40-4F F76x
wire io_any = io_rd | io_wr;
wire io_f4 = io_any && a[7:4] == 4'h1;
wire io_f5 = io_any && a[7:4] == 4'h2;
wire io_f76 = io_any && a[7:4] == 4'h4;
wire sel_f4 = (sel_dev && a[9:8] == 2'd0) || io_f4;
wire sel_f5 = (sel_dev && a[9:8] == 2'd1) || io_f5;
wire sel_f6 = sel_dev && a[9:8] == 2'd2;
wire sel_f7 = sel_dev && a[9:8] == 2'd3;
wire sel_f76 = (sel_f7 && a[7:4] == 4'h6) || io_f76;  // F760-F76F, the register in a[3:0]
wire wr_dev = mem_wr | io_wr;
wire rd_dev = mem_rd | io_rd;
wire sel_fdc, sel_rgu, fdc_drq;
wire sel_rtc_a = (sel_f76 && a[3:0] == 4'h0) || (sel_f7 && a[7:0] == 8'hB1);
wire sel_rtc_d = (sel_f76 && a[3:0] == 4'h1) || (sel_f7 && a[7:0] == 8'hB0);
reg [7:0] rtc_ar = 8'd0;
wire ay_io = z80 && a[15] && a[7:0] == 8'hFD;             // FFFD (A14 = 1), BFFD (A14 = 0)
wire sel_ay_mem = sel_f7 && a[7:4] == 4'hA;
wire [7:0] ay_do;
wire sdc_busy, sdc_done, sdc_error, sdc_in_strobe;
wire [2:0] sdc_slot;
wire [8:0] sdc_byte_addr;
wire [7:0] sdc_in_data;
wire [7:0] fdc_do;
wire [7:0] sdc_img_mounted;
reg key_irq = 1'b0;           // the keyboard interrupt of the Orion-2010
reg uart_irq = 1'b0;
reg [7:0] r76;                // a read of F762..F769
wire [1:0] hd_rd, hd_wr;
wire [63:0] sdc_img_size;

wire wr_any = mem_wr | io_wr;
reg wr_d = 1'b0;
always @(posedge clk)
	wr_d <= wr_any;
wire wr_p = wr_any & ~wr_d;   // one clock at the start of a write

// the latches: writes to F8xx.. or the ports F8.. of the Z80
wire mw = mem_wr && win;
wire lat_f8 = (mw && a[15:8] == 8'hF8) || (io_wr && a[7:0] == 8'hF8);
wire lat_f9 = (mw && a[15:8] == 8'hF9) || (io_wr && a[7:0] == 8'hF9);
wire lat_fa = (mw && a[15:8] == 8'hFA) || (io_wr && a[7:0] == 8'hFA);
wire lat_fb = z80 && ((mw && a[15:8] == 8'hFB) || (io_wr && a[7:0] == 8'hFB));
wire lat_fc = z80 && ((mw && a[15:8] == 8'hFC) || (io_wr && a[7:0] == 8'hFC));
wire lat_fe = z80 && io_wr && a[7:0] == 8'hFE;
wire lat_ff = z80 && io_wr && a[7:0] == 8'hFF;

reg [7:0] vmode = 8'd0;       // port F8: D3..0 the mode, D7 screen of 480 points
reg [7:0] pfa = 8'd0;         // port FA: D1..0 the screen, D7 screen of 512 points
reg [3:0] mbank = 4'd0;       // port F9: the page of 64 KB
reg [7:0] pfc = 8'd0;         // port FC: the colours of the pseudocolour mode
reg [4:0] pfe = 5'd0;         // port FE: D3..0 the page of the ROM disk, D4 sound
reg snd_ff = 1'b0;            // toggled by a write to port FF
// port FB, Z80 Card II: D7 = 0 the dispatcher: 0000-3FFF is the segment D1..0 of page D3..2;
// D6 interrupts, D5 all RAM
reg [7:0] fb = 8'h80;

always @(posedge clk) begin
	if (run_reset) begin
		vmode <= 8'd0;
		pfa <= 8'd0;
		mbank <= 4'd0;
		pfc <= 8'd0;
		pfe <= 5'd0;
		snd_ff <= 1'b0;
		fb <= 8'h80;
	end
	else if (wr_p) begin
		if (lat_f8) vmode <= cpu_do;
		if (lat_f9) mbank <= cpu_do[3:0];
		if (lat_fa) pfa <= cpu_do;
		if (lat_fb) fb <= cpu_do;
		if (lat_fc) pfc <= cpu_do;
		if (lat_fe) pfe <= cpu_do[4:0];
		if (lat_ff) snd_ff <= ~snd_ff;
	end
end

assign beep = z80 ? (pfe[4] ^ snd_ff) : inte;

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
assign int_n = !(z80 && (int_hold != 11'd0 || key_irq || uart_irq));

// the Monitor everywhere after reset
reg ipl = 1'b1;
always @(posedge clk)
	if (run_reset)
		ipl <= 1'b1;
	else if (mem_rd && top_f800)
		ipl <= 1'b0;

// ------------------------------------------------------------------ the PPIs
wire [7:0] ppi4_do, ppi5_do, ppi6_do;
wire [7:0] rd_pb, rd_pc;
wire rd_pa_in, us_pa_in;
wire [7:0] rd_pa, us_pa, us_pb, us_pc;
wire [7:0] ide_hi, ide_lo;
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

// the ROM disk: B and C are the address, A the byte; or the IDE (orion_ide), with A as an output
orion_ppi ppi_rd (
	.clk(clk), .reset(run_reset), .a(a[1:0]), .wr(wr_p & wr_dev & sel_f5), .din(cpu_do), .dout(ppi5_do),
	.pa_i(sram_do), .pb_i(ide_hi), .pc_i(ide_lo),
	.pa_in(rd_pa_in), .pa_o(rd_pa), .pb_o(rd_pb), .pc_o(rd_pc)
);

// the user port: the IDE of DSDOS
orion_ppi ppi_usr (
	.clk(clk), .reset(run_reset), .a(a[1:0]), .wr(wr_p & mem_wr & sel_f6), .din(cpu_do), .dout(ppi6_do),
	.pa_i(8'hFF), .pb_i(ide_hi), .pc_i(ide_lo),
	.pa_in(us_pa_in), .pa_o(us_pa), .pb_o(us_pb), .pc_o(us_pc)
);

// ------------------------------------------------------------------ the memory
wire disp = z80 && !fb[7] && a[15:14] == 2'b00;
wire [1:0] page_mask_hi = ram_size == 2'd0 ? 2'b00 : ram_size == 2'd1 ? 2'b01 : 2'b11;
wire [3:0] bank = mbank & { page_mask_hi, 2'b11 };
wire [3:0] page = disp ? { 2'b00, fb[3:2] } :
                  (!full && a[15:12] == 4'hF) ? 4'd0 : bank;  // F000-F3FF: always page 0
wire [15:0] ram_a = disp ? { fb[1:0], a[13:0] } : a;
wire [21:0] ram_addr = { 2'd0, page[3:1], ram_a, page[0] };

wire sel_rom = !mem_wr && !full && (ipl || (top_f800 && !p767[1]));
wire sel_rd = sel_f5 && a[1:0] == 2'd0;

wire [21:0] sram_addr = sel_rom ? { 10'b1000000000, mhi, a[10:0] } :
                        sel_rd  ? { 2'b01, pfe[3:2], pfe[1:0] | p767[4:3], rd_pc, rd_pb } :
                        ram_addr;
wire sram_we = mem_wr && !sel_dev && (!top_f800 || p767[2]);

always @* begin
	cpu_di = 8'hFF;
	if (inta && !mem_rd)      // the T80 shows M1 and IORQ together for a moment after reset
		cpu_di = uart_irq ? 8'hFD : key_irq ? 8'hFB : 8'hFF;
	else if (rd_dev && sel_f76 && a[3:0] >= 4'h2 && a[3:0] <= 4'h9)
		cpu_di = r76;
	else if (io_rd && io_f4)
		cpu_di = ppi4_do;
	else if (io_rd && io_f5)
		cpu_di = ppi5_do;
	else if (mem_rd) begin
		if (sel_rom) cpu_di = sram_do;
		else if (sel_f4) cpu_di = ppi4_do;
		else if (sel_f5) cpu_di = ppi5_do;
		else if (sel_f6) cpu_di = ppi6_do;
		else if (sel_rtc_a) cpu_di = rtc_ar;
		else if (sel_rtc_d) cpu_di = rtc_do;
		else if (sel_ay_mem && a[0]) cpu_di = ay_do;
		else if (sel_fdc) cpu_di = phys_now ? phys_do : fdc_do;
		else if (sel_rgu) cpu_di = { 6'd0, phys_now ? phys_drq : fdc_drq, 1'b0 };
		else if (!sel_dev) cpu_di = sram_do;
	end
	else if (io_rd && a[7:0] == 8'hFB)
		cpu_di = fb;
	else if (io_rd && ay_io && a[14])
		cpu_di = ay_do;
end

// ------------------------------------------------------------------ Orion-2010: F762..F76A
wire w76 = wr_p && wr_dev && sel_f76;
reg key_ie = 1'b0;            // F766 D6
reg [7:0] scan_key = 8'd0;
reg [1:0] key_pref = 2'd0;    // F769 D7..6: 1 E0, 2 a release
reg kb_ext = 1'b0, kb_rel = 1'b0;
reg kb_upd_d = 1'b0;
reg [7:0] dac_r = 8'd0;
wire [7:0] mmc_do;
reg rd76_d = 1'b0;

always @(posedge clk) begin
	kb_upd_d <= kb_scancode_upd;
	spd_osd <= cpu_speed;
	if (spd_osd != cpu_speed)
		spd <= cpu_speed;
	if (run_reset) begin
		p767 <= 8'd0;
		key_ie <= 1'b0;
		key_irq <= 1'b0;
		dac_r <= 8'd0;
		if (reset)
			spd <= cpu_speed;
	end
	else begin
		if (inta)
			key_irq <= 1'b0;
		if (w76 && a[3:0] == 4'h6)
			key_ie <= cpu_do[6];
		if (w76 && a[3:0] == 4'h7) begin
			p767[6:3] <= cpu_do[6:3];
			spd <= cpu_do[6:5] == 2'b10 ? 2'd0 : cpu_do[6:5] == 2'b00 ? 2'd1 : 2'd2;
			if (io_wr)
				p767[2:0] <= cpu_do[2:0];
		end
		if (w76 && a[3:0] == 4'hA)
			dac_r <= cpu_do;
	end
	// the scancodes: E0 and F0 are prefixes, a code is taken with them
	if (kb_scancode_upd != kb_upd_d) begin
		if (kb_scancode == 8'hE0)
			kb_ext <= 1'b1;
		else if (kb_scancode == 8'hF0)
			kb_rel <= 1'b1;
		else begin
			scan_key <= kb_scancode;
			key_pref <= { kb_rel, kb_ext & ~kb_rel };
			kb_ext <= 1'b0;
			kb_rel <= 1'b0;
			if (key_ie && z80 && !run_reset)
				key_irq <= 1'b1;
		end
	end
end
assign dac = dac_r;

// the UART: a byte of the mcu is there when its index changes, until a read of F764; a write of F764
// sends a byte (the mcu queues it, the transmitter is always ready); F765 D6 enables the interrupt of
// a received byte (vector FD). The speed bits are not used: the firmware has its own.
reg [7:0] uart_idx_d = 8'd0;
reg uart_rdy = 1'b0;
reg uart_ie = 1'b0;
reg rd764_d = 1'b0;
wire rd764 = rd_dev && sel_f76 && a[3:0] == 4'h4;
always @(posedge clk) begin
	uart_idx_d <= uart_rx_idx;
	rd764_d <= rd764;
	if (run_reset) begin
		uart_rdy <= 1'b0;
		uart_ie <= 1'b0;
		uart_irq <= 1'b0;
	end
	else begin
		if (uart_rx_idx != uart_idx_d) begin
			uart_rdy <= 1'b1;
			if (uart_ie && z80)
				uart_irq <= 1'b1;
		end
		else if (rd764_d && !rd764)
			uart_rdy <= 1'b0;
		if (w76 && a[3:0] == 4'h5)
			uart_ie <= cpu_do[6];
		if (inta && !mem_rd)
			uart_irq <= 1'b0;
	end
end
assign uart_tx_data = cpu_do;
assign uart_tx_wr = w76 && a[3:0] == 4'h4;

always @* begin
	case (a[3:0])
		4'h2: r76 = 8'hFF;
		4'h3: r76 = mmc_do;
		4'h4: r76 = uart_rx_data;                 // UART data
		4'h5: r76 = { 1'b0, uart_rdy, 6'h3F };    // UART: D7 0 the transmitter ready, D6 a byte received
		4'h7: r76 = { p767[7], p767_turbo, p767[4:3], p767[2:0] };
		4'h8: r76 = scan_key;
		4'h9: r76 = { key_pref, 6'd0 };
		default: r76 = 8'hFF;
	endcase
end

// the SD card: a read of F763 is taken at its end
wire rd76 = rd_dev && sel_f76 && a[3:0] == 4'h3;
always @(posedge clk)
	rd76_d <= rd76;
wire mmc_rd, mmc_wr;
wire [31:0] mmc_lba;
wire [7:0] mmc_byte_out;
reg mmc_own = 1'b0;            // the request of slot 6 in img_sdc is that of the SD card

orion_sd sd (
	.clk(clk),
	.reset(run_reset),
	.cs_wr(w76 && a[3:0] == 4'h2),
	.d_wr(w76 && a[3:0] == 4'h3),
	.din(cpu_do),
	.dout(mmc_do),
	.img_mounted(sdc_img_mounted[6]),
	.img_size(sdc_img_size[31:0]),
	.hd_rd(mmc_rd),
	.hd_wr(mmc_wr),
	.hd_lba(mmc_lba),
	.hd_busy(sdc_busy && sdc_slot == 3'd6 && mmc_own),
	.hd_done(sdc_done && sdc_slot == 3'd6 && mmc_own),
	.hd_byte_in_strobe(sdc_in_strobe && sdc_slot == 3'd6 && mmc_own),
	.hd_byte_addr(sdc_byte_addr),
	.hd_byte_in_data(sdc_in_data),
	.hd_byte_out_data(mmc_byte_out)
);
always @(posedge clk)
	if (mmc_rd || mmc_wr)
		mmc_own <= 1'b1;
	else if (hd_rd[0] || hd_wr[0])
		mmc_own <= 1'b0;

// ------------------------------------------------------------------ the clock
// the registers of the mcu (kg_mcu_rtc): a write is a clock long
always @(posedge clk)
	if (wr_p && mem_wr && sel_rtc_a)
		rtc_ar <= cpu_do;
assign rtc_a = rtc_ar;
assign rtc_di = cpu_do;
assign rtc_cs = wr_p && mem_wr && sel_rtc_d;
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
wire ay_wr_reg = wr_p && ((io_wr && ay_io && a[14]) || (mem_wr && sel_ay_mem && a[0]));
wire ay_wr_data = wr_p && ((io_wr && ay_io && !a[14]) || (mem_wr && sel_ay_mem && !a[0]));
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
wire [31:0] hd_sector;
wire [7:0] hd_byte_out;
wire sdc_hd = sdc_slot[2:1] == 2'b11;

orion_ide ide (
	.clk(clk),
	.reset(run_reset),
	.f5_on(!rd_pa_in),
	.f5_ctl(rd_pa),
	.f5_hi(rd_pb),
	.f5_lo(rd_pc),
	.f6_on(!us_pa_in),
	.f6_ctl(us_pa),
	.f6_hi(us_pb),
	.f6_lo(us_pc),
	.do_hi(ide_hi),
	.do_lo(ide_lo),
	.img_mounted(sdc_img_mounted[7:6]),
	.img_size(sdc_img_size),
	.sdc_rd(hd_rd),
	.sdc_wr(hd_wr),
	.sdc_sector(hd_sector),
	.sdc_busy(sdc_busy && sdc_hd && !(sdc_slot == 3'd6 && mmc_own)),
	.sdc_done(sdc_done && sdc_hd && !(sdc_slot == 3'd6 && mmc_own)),
	.sdc_error(sdc_error && sdc_hd && !(sdc_slot == 3'd6 && mmc_own)),
	.sdc_byte_in_strobe(sdc_in_strobe && sdc_hd && !(sdc_slot == 3'd6 && mmc_own)),
	.sdc_byte_addr(sdc_byte_addr),
	.sdc_byte_in_data(sdc_in_data),
	.sdc_byte_out_data(hd_byte_out)
);

// ------------------------------------------------------------------ the disk drive
// KR1818VG93 at F700-F703, F710-F713 (an incomplete decoder), the control register at F704, F714,
// F720: D0 the drive, D4 the side, inverted. Read, the control register shows DRQ in D1.
// F708, F718 is the same register of the controller by M. Korotkin: D0 the side, D1 the drive
// (DSDOS writes there when F704 does not read FF).
assign sel_fdc = sel_f7 && a[7:5] == 3'd0 && a[3:2] == 2'd0;
assign sel_rgu = sel_f7 && (a[7:0] == 8'h20 || (a[7:5] == 3'd0 && a[3:0] == 4'd4));
wire sel_rgk = sel_f7 && a[7:5] == 3'd0 && a[3:0] == 4'd8;

reg [7:0] rgu = 8'd0;
always @(posedge clk)
	if (run_reset)
		rgu <= 8'd0;
	else if (wr_p && mem_wr && sel_rgu)
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
			.sel(sel_fdc & phys_now), .a(a[1:0]), .rd(mem_rd), .wr(mem_wr), .din(cpu_do),
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
	.rd(mem_rd),
	.wr(mem_wr),
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
	.sdc_rd({ hd_rd[1], hd_rd[0] | mmc_rd, sdc_rd_b, sdc_rd_a, 4'd0 }),
	.sdc_wr({ hd_wr[1], hd_wr[0] | mmc_wr, sdc_wr_b, sdc_wr_a, 4'd0 }),
	.sdc_sector((sdc_rd_a || sdc_wr_a) ? sdc_sector_a : (sdc_rd_b || sdc_wr_b) ? sdc_sector_b :
		(mmc_rd || mmc_wr) ? mmc_lba : hd_sector),
	.sdc_busy(sdc_busy),
	.sdc_done(sdc_done),
	.sdc_error(sdc_error),
	.sdc_slot(sdc_slot),
	.sdc_byte_in_strobe(sdc_in_strobe),
	.sdc_byte_addr(sdc_byte_addr),
	.sdc_byte_in_data(sdc_in_data),
	.sdc_byte_out_data((sdc_slot == 3'd6 && mmc_own) ? mmc_byte_out : sdc_hd ? hd_byte_out :
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
wire [20:0] vid_addr;
wire [15:0] vid_dout;

wire v6_req, v5_req;
wire [20:0] v6_addr, v5_addr;
wire [23:0] v6_rgb, v5_rgb;
wire v6_hs, v6_vs, v6_de, v5_hs, v5_vs, v5_de;

orion_video video (
	.clk(clk),
	.vmode(vmode[3:0]),
	.vpage(pfa[1:0]),
	.w512(pfa[7]),
	.w480(vmode[7]),
	.pcolor(pfc),
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
	.vmode(vmode[3:0]),
	.vpage(pfa[1:0]),
	.w512(pfa[7]),
	.w480(vmode[7]),
	.pcolor(pfc),
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
