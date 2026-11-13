`timescale 1ns / 1ps
`default_nettype wire

/*
 Orion-128 core for Karabas Mini before rev.G (HDMI, sigma-delta audio on AUDIO_L / AUDIO_R).
 The same as karabas_minig_top.v except the pins (as core-msx): no PCM5102, MCU_SCK not on a clock
 pin (no IBUFG / BUFG), FT_CLK_OUT on E7 (MCU_IO<4> of the FT812 clock mod).

 The machine is orionpro_system; all file work goes through the firmware: the ROMs of core.json by the
 ROM loader, a ROM disk, a Monitor and ORDOS files by the FL items of the OSD (orion_loader).

 Clocks: one PLL, VCO 800 MHz (50 * 16): clk_sys 40.0 MHz (/20: everything, 800 x 600 output),
 clk_8 8.0 MHz (/100, FT_CLK_OUT: the FT812 must always have its clock, see karabas-go-notes
 ft-clk-out-required). HDMI: kg_dcm 5 x clk_sys and its inverse.

 Soft switches (the index of the item in the osd of core.json, file items included):
   0 Disk A (F 4)   1 Disk B (F 5)   2 HDD master (F 6)   3 HDD slave (F 7)   4 ROM disk (FL 0)
   5 ORDOS file (FL 1)   6 ROM1 (FL 3)   7 ROM2 (FL 2)   8 -   9 Boot (Menu / PRO / Orion-128)
   10 CPU speed (2.5 / 5 / 10 MHz)   11 RAM (512 KB / 1 / 2 MB)   12 Keyboard (RK-86 / MS7007)
   13 Video (800 x 600 60 Hz / 720 x 576 50 Hz)   14 Reset
*/

module karabas_mini_top (
	input wire CLK_50MHZ,

	inout wire UART_RX,
	inout wire UART_TX,
	inout wire UART_CTS,
	inout wire ESP_RESET_N,
	inout wire ESP_BOOT_N,

	output wire [20:0] MA,
	inout wire [15:0] MD,
	output wire [1:0] MWR_N,
	output wire [1:0] MRD_N,

	output wire [1:0] SDR_BA,
	output wire [12:0] SDR_A,
	output wire SDR_CLK,
	output wire [1:0] SDR_DQM,
	output wire SDR_WE_N,
	output wire SDR_CAS_N,
	output wire SDR_RAS_N,
	inout wire [15:0] SDR_DQ,

	output wire SD_CS_N,
	output wire SD_CLK,
	output wire SD_DI,
	input wire SD_DO,
	input wire SD_DET_N,

	input wire [7:0] VGA_R,
	input wire [7:0] VGA_G,
	input wire [7:0] VGA_B,
	input wire VGA_HS,
	input wire VGA_VS,

	output wire [3:0] TMDS_P,
	output wire [3:0] TMDS_N,

	output wire FT_SPI_CS_N,
	output wire FT_SPI_SCK,
	input wire FT_SPI_MISO,
	output wire FT_SPI_MOSI,
	input wire FT_INT_N,
	input wire FT_CLK,
	input wire FT_DE,
	input wire FT_AUDIO,
	input wire FT_DISP,
	output wire FT_RESET,
	output wire FT_CLK_OUT,

	output wire [2:0] WA,
	output wire [1:0] WCS_N,
	output wire WRD_N,
	output wire WWR_N,
	output wire WRESET_N,
	inout wire [15:0] WD,

	output wire TAPE_OUT,
	input wire TAPE_IN,

	output wire AUDIO_L,
	output wire AUDIO_R,

	output wire ADC_CLK,
	inout wire ADC_BCK,
	inout wire ADC_LRCK,
	input wire ADC_DOUT,

	input wire MCU_CS_N,
	input wire MCU_SCK,
	inout wire MCU_MOSI,
	output wire MCU_MISO,
	inout wire [3:0] MCU_IO, // [1] INT of link v2, [2] sd2 cs_n, [3] ft cs_n

	output wire MIDI_TX,

	output wire MIDI_CLK,
	output wire MIDI_RESET_N,

	output wire FLASH_CS_N,
	input wire FLASH_DO,
	output wire FLASH_DI,
	output wire FLASH_SCK,
	output wire FLASH_WP_N,
	output wire FLASH_HOLD_N
);

// ------------------------------------------------------------------ unused

assign SDR_BA = 2'b11;
assign SDR_A = 13'h1FFF;
assign SDR_CLK = 1'b1;
assign SDR_DQM = 2'b11;
assign SDR_WE_N = 1'b1;
assign SDR_CAS_N = 1'b1;
assign SDR_RAS_N = 1'b1;
assign SDR_DQ = 16'bz;

assign WA = 3'b000;
assign WCS_N = 2'b11;
assign WRD_N = 1'b1;
assign WWR_N = 1'b1;
assign WRESET_N = 1'b1;
assign WD = 16'bz;

assign ESP_RESET_N = 1'bz;
assign ESP_BOOT_N = 1'bz;
assign FT_RESET = 1'b1;
assign MIDI_CLK = 1'b1;
assign MIDI_RESET_N = 1'b1;
assign MIDI_TX = 1'b1;
assign UART_RX = 1'bz;
assign UART_TX = 1'bz;
assign UART_CTS = 1'bz;

assign FLASH_CS_N = 1'b1;
assign FLASH_DI = 1'b1;
assign FLASH_SCK = 1'b0;
assign FLASH_WP_N = 1'b1;
assign FLASH_HOLD_N = 1'b1;

assign ADC_CLK = 1'b0;
assign ADC_BCK = 1'bz;
assign ADC_LRCK = 1'bz;

assign MRD_N = 2'b00;  // SRAM /OE: always on, orion_sram drives MD only with /WE

// ------------------------------------------------------------------ clocks

wire clk_sys, clk_8;
wire locked, lockedx5, areset;
wire clk_hdmi, clk_hdmi_n;

wire [5:0] pll_clk;
kg_pll #(
	.CLKIN_PERIOD(20.0),
	.DIVCLK_DIVIDE(1),
	.CLKFBOUT_MULT(16),
	.CLKOUT0_DIVIDE(20),
	.CLKOUT1_DIVIDE(100),
	.CLKOUT2_DIVIDE(20),
	.BUFG_MASK(6'b000011)  // clk_out[2] raw: the BUFGMUX of the pixel clock
) pll (
	.clk_in(CLK_50MHZ),
	.rst(1'b0),
	.clk_out(pll_clk),
	.locked(locked)
);
assign clk_sys = pll_clk[0];
assign clk_8 = pll_clk[1];
assign areset = ~locked;

// the pixel clock: clk_sys for 800 x 600 at 60 Hz, 27.0 MHz for 720 x 576 at
// 50 Hz (Video in the OSD), of a second PLL on clk_sys (40 * 27 / 2 / 20: less jitter than a DCM for the
// HDMI serialiser after it). BUFGMUX takes the raw outputs: the third output of the first PLL (40 MHz,
// the twin of clk_sys) and that of pll27.
wire clk40_raw = pll_clk[2];
wire clk27_raw, locked27;
wire [5:0] pll27_clk;
kg_pll #(
	.CLKIN_PERIOD(25.0),
	.DIVCLK_DIVIDE(2),
	.CLKFBOUT_MULT(27),     // VCO 540 MHz
	.CLKOUT0_DIVIDE(20),    // 27.0 MHz
	.BUFG_MASK(6'b000000),  // raw: the BUFGMUX of the pixel clock
	.IBUFG(0)
) pll27 (
	.clk_in(clk_sys),
	.rst(areset),
	.clk_out(pll27_clk),
	.locked(locked27)
);
assign clk27_raw = pll27_clk[0];
wire pal;                     // 720 x 576 at 50 Hz (sw_video, from the soft switches)
wire clk_pix;
BUFGMUX pixmux (.I0(clk40_raw), .I1(clk27_raw), .S(pal), .O(clk_pix));

// a change of the video mode: the pixel clock changes, the clocks after it restart
reg pal_d = 1'b0;
reg [7:0] vrst = 8'hFF;
always @(posedge clk_sys) begin
	pal_d <= pal;
	if (pal != pal_d || areset || (pal && !locked27))
		vrst <= 8'hFF;
	else if (vrst != 8'd0)
		vrst <= vrst - 8'd1;
end
wire video_reset = vrst != 8'd0;

kg_dcm #(
	.CLKIN_PERIOD(25.0),
	.CLKFX_MULTIPLY(5),
	.CLKFX_DIVIDE(1)
) pllx5 (
	.clk_in(clk_pix),
	.rst(video_reset),
	.clk_fx(clk_hdmi),
	.clk_fx180(clk_hdmi_n),
	.clk_0(),
	.locked(lockedx5)
);

// the clock of the FT812
ODDR2 oddr_ft_clk (.Q(FT_CLK_OUT), .C0(clk_8), .C1(~clk_8), .CE(1'b1), .D0(1'b1), .D1(1'b0), .R(1'b0), .S(1'b0));

// ------------------------------------------------------------------ MCU


wire mcu_sck = MCU_SCK, mcu_sck_ibufg = MCU_SCK;  // not on a clock pin before rev.G

// karabas: MCU link v2 (karabas-go-firmware docs/link_v2.md, kg_mcu2); INT on IO1
wire mcu_int;
assign MCU_IO[1] = mcu_int;
assign MCU_IO[0] = 1'bz;
assign MCU_IO[3:2] = 2'bzz;

wire [7:0] kb_scancode;
wire [7:0] uart_rx_data, uart_rx_idx;
wire [7:0] uart_tx_data;
wire uart_tx_wr;
wire [15:0] joy_l16, joy_r16;
wire [12:0] joy_l = joy_l16[12:0], joy_r = joy_r16[12:0];
wire [1:0] ld_kind;
wire [7:0] ld_slot, ld_data;
wire [31:0] ld_addr;
wire ld_active, ld_wr;
wire [17*8-1:0] sw;
wire mcu_busy;
wire dvi_only;
wire ft_cs_n, ft_mosi, ft_spi_on, sd2_cs_n, sd2_mosi;
wire [7:0] img_wp;
wire [7:0] rtc_a, rtc_di, rtc_do;
wire rtc_cs, rtc_wr_n;
wire [7:0] ps2_code;
wire ps2_kind, ps2_wr;
wire [7:0] ms_x, ms_y, ms_b8;
wire [2:0] ms_b = ms_b8[2:0];
wire ms_wr;
wire [31:0] port_out_data;
wire [3:0] port_out_wr;
wire osd_wr, osd_en, osd_zoom;
wire [11:0] osd_waddr;
wire [7:0] osd_wdata;
wire [23:0] osd_fg, osd_bg;
wire [1:0] osd_alpha, osd_place;
wire [4:0] osd_px, osd_ph;
wire [3:0] osd_py;
wire [5:0] osd_pw;
// the disks: the mounter of kg_mcu2 (the sector interface of img_sdc) to orionpro_system
wire [7:0] sdc_img_mounted, sdc_rd, sdc_wr, sdc_byte_in_data, sdc_byte_out_data;
wire [63:0] sdc_img_size;
wire [31:0] sdc_sector;
wire sdc_busy, sdc_done, sdc_error, sdc_byte_in_strobe;
wire [2:0] sdc_slot;
wire [8:0] sdc_byte_addr;

kg_mcu2 #(
	.CAPS(16'h0004),     // write protected images
	.SW_N(17),
	.CS_FILTER(3),
	.ENABLE_OSD(1),
	.ENABLE_IMG(1),      // the disks: the images of the F items
	.IMG_OUT_LATENCY(3),
	.ENABLE_PORTS(4'b0001), // port 0: COM1 (8251 at 30 / 31), 115200
	.ENABLE_RTC(1),
	.RTC_SKIP_0D(1),     // C and D are flags of the MC146818
	.ENABLE_FT(1),
	.ENABLE_SD2(1)
) mcu (
	.CLK(clk_sys),
	.N_RESET(~areset),

	.MCU_SCK(mcu_sck),
	.MCU_MOSI(MCU_MOSI),
	.MCU_MISO(MCU_MISO),
	.MCU_SS(MCU_CS_N),
	.MCU_INT(mcu_int),
	.MCU_SPI_FT_SS(MCU_IO[3]),
	.MCU_SPI_SD2_SS(MCU_IO[2]),

	.SW(sw), .SW_WR(), .SW_INDEX(), .SW_VALUE(), .HW_ID(), .DVI_ONLY(dvi_only), .CORE_BUILD(), .FW_BUILD(),
	.BUSY(mcu_busy), .BTNS(), .RELOAD_REQ(1'b0), .RELOAD_CORE(8'd0),

	.KBD(), .KBD_WR(), .PS2_CODE(ps2_code), .PS2_KIND(ps2_kind), .PS2_WR(ps2_wr),
	.MS_X(ms_x), .MS_Y(ms_y), .MS_Z(), .MS_B(ms_b8), .MS_WR(ms_wr),
	.JOY_L(joy_l16), .JOY_R(joy_r16), .JOY_WR(),
	.PS2_CMD(16'h0000), .PS2_CMD_WR(1'b0),

	.LD_KIND(ld_kind), .LD_SLOT(ld_slot), .LD_SIZE(), .LD_START(), .LD_ACTIVE(ld_active), .LD_END(),
	.LD_ADDR(ld_addr), .LD_DATA(ld_data), .LD_WR(ld_wr), .LD_READY(1'b1),

	.OSD_WR(osd_wr), .OSD_WADDR(osd_waddr), .OSD_WDATA(osd_wdata), .OSD_EN(osd_en),
	.OSD_FG(osd_fg), .OSD_BG(osd_bg), .OSD_ALPHA(osd_alpha), .OSD_PX(osd_px), .OSD_PY(osd_py),
	.OSD_PW(osd_pw), .OSD_PH(osd_ph), .OSD_PLACE(osd_place), .OSD_ZOOM(osd_zoom),

	.SDC_IMG_MOUNTED(sdc_img_mounted), .SDC_IMG_SIZE(sdc_img_size),
	.SDC_RD(sdc_rd), .SDC_WR(sdc_wr), .SDC_SECTOR(sdc_sector),
	.SDC_BUSY(sdc_busy), .SDC_DONE(sdc_done), .SDC_ERROR(sdc_error), .SDC_SLOT(sdc_slot),
	.SDC_BYTE_IN_STROBE(sdc_byte_in_strobe), .SDC_BYTE_ADDR(sdc_byte_addr),
	.SDC_BYTE_IN_DATA(sdc_byte_in_data), .SDC_BYTE_OUT_DATA(sdc_byte_out_data),
	.IMG_WP(img_wp), .IMG_PHYS_WR(), .IMG_PHYS(), .IMG_FLUSH(), .FDD_CHNG_WR(), .FDD_CHNG(),
	.FDD_CHNG_REQ(1'b0), .FDD_CHNG_DS(2'd0), .IMG_ACTIVE(),

	.PORT_OUT_DATA(port_out_data), .PORT_OUT_WR(port_out_wr), .PORT_OUT_READY(4'b1111),
	.PORT_IN_DATA({ 24'd0, uart_tx_data }), .PORT_IN_WR({ 3'b000, uart_tx_wr }),
	.PORT_CFG(128'd0), .PORT_IN_FULL(), .PORT_STAT(), .PORT_STAT_WR(),
	.RTC_A(rtc_a), .RTC_DI(rtc_di), .RTC_CS(rtc_cs), .RTC_WR_N(rtc_wr_n), .MATRIX_CMD(24'd0), .MATRIX_CMD_WR(1'b0),
	.DEBUG_ADDR(16'd0), .DEBUG_DATA(16'd0), .RTC_DO(rtc_do),

	.FT_SPI_ON(ft_spi_on), .FT_VGA_ON(), .FT_RESET(), .FT_SCK(), .FT_MOSI(ft_mosi), .FT_MISO(FT_SPI_MISO),
	.FT_CS_N(ft_cs_n),
	.SD2_SCK(), .SD2_MOSI(sd2_mosi), .SD2_MISO(SD_DO), .SD2_CS_N(sd2_cs_n)
);

// the loads of link v2 on the loader signals of orionpro_system: the roms of the core file (LD kind 0),
// the FL items (kind 2)
wire rom_active = ld_active && ld_kind == 2'd0;
wire rom_wr = ld_wr && ld_kind == 2'd0;
wire [31:0] rom_addr = ld_addr;
wire [7:0] rom_data = ld_data;
wire file_active = ld_active && ld_kind == 2'd2;
wire file_wr = ld_wr && ld_kind == 2'd2;
wire [7:0] file_slot = ld_slot, file_data = ld_data;
wire [31:0] file_addr = ld_addr;

// the toggles of v1 out of the pulses of v2: the PS/2 scancode (set 2), the mouse report and the
// UART byte with a counter that changes with it (orionpro_system takes a change of them)
reg kb_upd_t = 1'b0, ms_upd = 1'b0;
reg [7:0] kb_code_r = 8'd0, uart_rx_data_r = 8'd0, uart_rx_idx_r = 8'd0;
always @(posedge clk_sys) begin
	if (ps2_wr && !ps2_kind) begin
		kb_code_r <= ps2_code;
		kb_upd_t <= ~kb_upd_t;
	end
	if (ms_wr)
		ms_upd <= ~ms_upd;
	if (port_out_wr[0]) begin
		uart_rx_data_r <= port_out_data[7:0];
		uart_rx_idx_r <= uart_rx_idx_r + 1'b1;
	end
end
assign kb_scancode = kb_code_r;
wire kb_scancode_upd = kb_upd_t;
assign uart_rx_data = uart_rx_data_r;
assign uart_rx_idx = uart_rx_idx_r;

assign FT_SPI_CS_N = ft_spi_on ? ft_cs_n : 1'b1;
assign FT_SPI_SCK = ft_spi_on ? mcu_sck_ibufg : 1'b1;
assign FT_SPI_MOSI = ft_spi_on ? ft_mosi : 1'b1;
assign SD_CS_N = sd2_cs_n;
assign SD_DI = sd2_mosi;
assign SD_CLK = mcu_sck_ibufg;

// ------------------------------------------------------------------ soft switches

// the switches: the SW registers of kg_mcu2
wire [1:0] sw_boot = sw[9*8 +: 2];
wire [1:0] sw_speed = sw[10*8 +: 2];
wire [1:0] sw_ram = sw[11*8 +: 2];
wire sw_ms7007 = sw[12*8];
wire sw_reset = sw[14*8];
assign pal = sw[13*8];

// ------------------------------------------------------------------ the machine

wire [23:0] video_rgb;
wire video_hs, video_vs, video_de;
wire beep;
wire [9:0] ay_sound;
wire [7:0] dac8 = 8'd0;

orionpro_system #(.LINK(2)) orion (
	.clk(clk_sys),
	.reset(areset || sw_reset || mcu_busy),
	.boot(sw_boot),
	.cpu_speed(sw_speed),
	.ram_size(sw_ram),
	.kb_ms7007(sw_ms7007),
	.uart_rx_data(uart_rx_data), .uart_rx_idx(uart_rx_idx), .uart_tx_data(uart_tx_data), .uart_tx_wr(uart_tx_wr),
	.ms_x(ms_x), .ms_y(ms_y), .ms_b(ms_b), .ms_upd(ms_upd),
	.joy(joy_l | joy_r),
	.rom_active(rom_active),
	.rom_addr(rom_addr[21:0]),
	.rom_data(rom_data),
	.rom_wr(rom_wr),
	.file_active(file_active),
	.file_slot(file_slot),
	.file_addr(file_addr),
	.file_data(file_data),
	.file_wr(file_wr),
	.img_mounted(8'd0),
	.img_size(64'd0),
	.img_wp(img_wp),
	.img_data_wr(1'b0),
	.img_data_addr(9'd0),
	.img_data(8'd0),
	.img_result_wr(1'b0),
	.img_result(8'd0),
	.img_sum(16'd0),
	.img_q_wr(),
	.img_q_di(),
	.img_q_ack(1'b0),
	.sdc_img_mounted_i(sdc_img_mounted), .sdc_img_size_i(sdc_img_size), .sdc_rd_o(sdc_rd), .sdc_wr_o(sdc_wr),
	.sdc_sector_o(sdc_sector), .sdc_busy_i(sdc_busy), .sdc_done_i(sdc_done), .sdc_error_i(sdc_error),
	.sdc_slot_i(sdc_slot), .sdc_byte_in_strobe_i(sdc_byte_in_strobe), .sdc_byte_addr_i(sdc_byte_addr),
	.sdc_byte_in_data_i(sdc_byte_in_data), .sdc_byte_out_data_o(sdc_byte_out_data),
	.kb_scancode(kb_scancode),
	.kb_scancode_upd(kb_scancode_upd),
	.clk_pix(clk_pix),
	.pal(pal),
	.rgb(video_rgb),
	.hs(video_hs),
	.vs(video_vs),
	.de(video_de),
	.rtc_a(rtc_a),
	.rtc_di(rtc_di),
	.rtc_do(rtc_do),
	.rtc_cs(rtc_cs),
	.rtc_wr_n(rtc_wr_n),
	.beep(beep),
	.ay_sound(ay_sound),
	.img_phys_wr(1'b0),
	.img_phys(16'd0),
	.FDC_INDEX(1'b0), .FDC_DRIVE(), .FDC_MOTOR(), .FDC_DIR(), .FDC_STEP(), .FDC_WDATA(), .FDC_WGATE(),
	.FDC_TR00(1'b0), .FDC_WPRT(1'b0), .FDC_RDATA(1'b0), .FDC_SIDE_N(),
	.tape_in(TAPE_IN),
	.tape_out(TAPE_OUT),
	.MA(MA),
	.MD(MD),
	.MWR_N(MWR_N)
);

// ------------------------------------------------------------------ OSD

// the bitmap OSD of link v2 (kg_l2_osd_overlay): written on clk_sys, shown on clk_pix (800 x 600 or
// 720 x 576), centred in de, 2 clocks of latency with its syncs and de
wire [23:0] osd_rgb;
wire osd_hs, osd_vs, osd_de;
kg_l2_osd_overlay osd (
	.wclk(clk_sys),
	.osd_wr(osd_wr), .osd_waddr(osd_waddr), .osd_wdata(osd_wdata), .osd_en(osd_en),
	.osd_fg(osd_fg), .osd_bg(osd_bg), .osd_alpha(osd_alpha), .osd_px(osd_px), .osd_py(osd_py),
	.osd_pw(osd_pw), .osd_ph(osd_ph), .osd_place(osd_place), .osd_zoom(osd_zoom),
	.icon_on(8'd0), .icon_act(8'd0),
	.clk(clk_pix),
	.rgb_i(video_rgb), .hs_i(video_hs), .vs_i(video_vs), .de_i(video_de),
	.rgb_o(osd_rgb), .hs_o(osd_hs), .vs_o(osd_vs), .de_o(osd_de)
);

// ------------------------------------------------------------------ audio

wire [15:0] audio = (beep ? 16'h1800 : 16'h0000) + (TAPE_OUT ? 16'h0400 : 16'h0000) + { 2'b00, ay_sound, 4'b0000 } + { 3'b000, dac8, 5'b00000 };

kg_sigma_delta_dac dac_l (.clk(clk_sys), .reset(areset), .din(audio), .dout(AUDIO_L));
kg_sigma_delta_dac dac_r (.clk(clk_sys), .reset(areset), .din(audio), .dout(AUDIO_R));

// ------------------------------------------------------------------ HDMI

// the audio sample into clk_pix: held on clk_sys at 48 kHz (a toggle tells), taken on clk_pix at the
// change of the synchronised toggle (the sample is stable then: it changes 20 us later), as core-msx
reg [15:0] smp = 16'd0;
reg smp_tog = 1'b0;
reg [11:0] smp_acc = 12'd0;   // 48 kHz from 40 MHz: + 3 per clock, modulo 2500
always @(posedge clk_sys) begin
	if (smp_acc >= 12'd2500 - 12'd3) begin
		smp_acc <= smp_acc + 12'd3 - 12'd2500;
		smp <= audio;
		smp_tog <= ~smp_tog;
	end
	else
		smp_acc <= smp_acc + 12'd3;
end
wire smp_tog_pix;
kg_sync smp_sync (.clk(clk_pix), .d(smp_tog), .q(smp_tog_pix));
reg smp_tog_pix_d = 1'b0;
reg [23:0] hdmi_smp = 24'd0;
always @(posedge clk_pix) begin
	smp_tog_pix_d <= smp_tog_pix;
	if (smp_tog_pix != smp_tog_pix_d)
		hdmi_smp <= { smp, 8'd0 };
end

// the audio sample clock of hdmi_tx: 48 kHz of clk_pix (40 MHz: + 3 per clock modulo 2500; 27 MHz:
// + 16 modulo 9000)
reg [13:0] aud_acc = 14'd0;
reg aud_stb = 1'b0;
wire [13:0] aud_step = pal ? 14'd16 : 14'd3;
wire [13:0] aud_mod = pal ? 14'd9000 : 14'd2500;
always @(posedge clk_pix) begin
	aud_stb <= 1'b0;
	if (aud_acc >= aud_mod - aud_step) begin
		aud_acc <= aud_acc + aud_step - aud_mod;
		aud_stb <= 1'b1;
	end
	else
		aud_acc <= aud_acc + aud_step;
end
wire dvi_only_pix;
kg_sync dvi_sync (.clk(clk_pix), .d(dvi_only), .q(dvi_only_pix));

// 800 x 600: positive syncs; 720 x 576: negative
hdmi_tx #(.SAMPLE_FREQ(48000)) hdmi (
	.clk(clk_pix),
	.sclk(clk_hdmi),
	.sclk_n(clk_hdmi_n),
	.reset(video_reset || ~lockedx5),
	.rgb(osd_rgb),
	.vsync(pal ? ~osd_vs : osd_vs),
	.hsync(pal ? ~osd_hs : osd_hs),
	.de(osd_de),
	.audio_en(~dvi_only_pix),
	.audio_l(hdmi_smp),
	.audio_r(hdmi_smp),
	.audio_clk(aud_stb),
	.tx_clk_n(TMDS_N[3]),
	.tx_clk_p(TMDS_P[3]),
	.tx_d_n(TMDS_N[2:0]),
	.tx_d_p(TMDS_P[2:0])
);

endmodule
