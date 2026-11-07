`timescale 1ns / 1ps
`default_nettype wire

/*
 Orion-128 core for Karabas Mini before rev.G (HDMI, sigma-delta audio on AUDIO_L / AUDIO_R).
 The same as karabas_minig_top.v except the pins (as core-msx): no PCM5102, MCU_SCK not on a clock
 pin (bursts at the link clock, no IBUFG / BUFG), FT_CLK_OUT on E7 (MCU_IO<4> of the FT812 clock mod).

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
	inout wire [3:0] MCU_IO, // [0] burst cs_n, [1] burst ready, [2] sd2 cs_n, [3] ft cs_n

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


wire mcu_burst_ready;
wire mcu_sck = MCU_SCK, mcu_sck_ibufg = MCU_SCK;  // not on a clock pin before rev.G
assign MCU_IO[1] = mcu_burst_ready;
assign MCU_IO[0] = 1'bz;
assign MCU_IO[3:2] = 2'bzz;

wire [7:0] kb_scancode;
wire [7:0] uart_rx_data, uart_rx_idx;
wire [7:0] uart_tx_data;
wire uart_tx_wr;
wire [12:0] joy_l, joy_r;
wire kb_scancode_upd;
wire rom_active, rom_wr;
wire [31:0] rom_addr;
wire [7:0] rom_data;
wire file_active, file_wr;
wire [7:0] file_slot, file_data;
wire [31:0] file_addr;
wire [15:0] softsw_command, osd_command;
wire mcu_busy;
wire dvi_only;
wire ft_cs_n, ft_mosi, ft_spi_on, sd2_cs_n, sd2_mosi;
wire [7:0] img_mounted, img_data, img_result, img_wp;
wire [63:0] img_size;
wire img_data_wr, img_result_wr, img_q_wr, img_q_ack;
wire [8:0] img_data_addr;
wire [15:0] img_sum;
wire [23:0] img_q_di;
wire [7:0] rtc_a, rtc_di, rtc_do;
wire rtc_cs, rtc_wr_n;

wire [7:0] ms_x, ms_y;
wire [2:0] ms_b;
wire ms_upd;
kg_mcu #(
	.BURST_MAX_MHZ(0),   // MCU_SCK is not on a clock pin before rev.G: bursts at the link clock
	.CS_FILTER(3),
	.ENABLE_RTC(1),
	.RTC_SKIP_0D(1),     // C and D are flags of the MC146818
	.ENABLE_UART(1),     // COM1 (8251 at 30 / 31)
	.ENABLE_MATRIX(0),
	.ENABLE_DEBUG(0),
	.ENABLE_IMG(1),      // the disks: the images of the F items
	.ENABLE_IMG_WP(1),
	.ENABLE_FILE(1),
	.FILE_CMDS(0),       // the ioctl commands of the FL items
	.FILE_WR_EACH(1),
	.FILE_TO_ROM(0),
	.ENABLE_FT(1),
	.ENABLE_SD2(1)
) mcu (
	.CLK(clk_sys),
	.N_RESET(~areset),

	.MCU_MOSI(MCU_MOSI),
	.MCU_MISO(MCU_MISO),
	.MCU_SCK(mcu_sck),
	.MCU_SS(MCU_CS_N),
	.MCU_SPI_FT_SS(MCU_IO[3]),
	.MCU_SPI_SD2_SS(MCU_IO[2]),
	.MCU_BURST_CS_N(MCU_IO[0]),
	.MCU_BURST_READY(mcu_burst_ready),

	.KB_SCANCODE(kb_scancode),
	.KB_SCANCODE_UPD(kb_scancode_upd),
	.JOY_L(joy_l),
	.JOY_R(joy_r),
	.MS_X(ms_x),
	.MS_Y(ms_y),
	.MS_B(ms_b),
	.MS_Z(),
	.MS_UPD(ms_upd),

	.ROMLOADER_ACTIVE(rom_active),
	.ROMLOAD_ADDR(rom_addr),
	.ROMLOAD_DATA(rom_data),
	.ROMLOAD_WR(rom_wr),

	.FILELOAD_ACTIVE(file_active),
	.FILELOAD_ADDR(file_addr),
	.FILELOAD_DATA(file_data),
	.FILELOAD_WR(file_wr),
	.FILELOAD_SLOT(file_slot),

	.SOFTSW_COMMAND(softsw_command),
	.OSD_COMMAND(osd_command),
	.BUSY(mcu_busy),

	.FT_SPI_ON(ft_spi_on),
	.FT_CS_N(ft_cs_n),
	.FT_MOSI(ft_mosi),
	.FT_MISO(FT_SPI_MISO),
	.FT_SCK(),
	.SD2_CS_N(sd2_cs_n),
	.SD2_MOSI(sd2_mosi),
	.SD2_MISO(SD_DO),
	.SD2_SCK(),

	.DVI_ONLY(dvi_only),

	// not used by this core
	.PS2_COMMAND(16'h0000),
	.PS2_COMMAND_WR(1'b0),
	.RTC_A(rtc_a),
	.RTC_DI(rtc_di),
	.RTC_DO(rtc_do),
	.RTC_CS(rtc_cs),
	.RTC_WR_N(rtc_wr_n),
	.UART_RX_DATA(uart_rx_data),
	.UART_RX_IDX(uart_rx_idx),
	.UART_TX_DATA(uart_tx_data),
	.UART_TX_WR(uart_tx_wr),
	.UART_TX_MODE(1'b0),
	.UART_DLM(8'h00),
	.UART_DLL(8'h00),
	.UART_DLM_WR(1'b0),
	.UART_DLL_WR(1'b0),
	.MATRIX_CMD(24'h000000),
	.MATRIX_CMD_WR(1'b0),
	.DEBUG_ADDR(16'h0000),
	.DEBUG_DATA(16'h0000),
	.IMG_MOUNTED(img_mounted),
	.IMG_SIZE(img_size),
	.IMG_WP(img_wp),
	.IMG_DATA_WR(img_data_wr),
	.IMG_DATA_ADDR(img_data_addr),
	.IMG_DATA(img_data),
	.IMG_RESULT_WR(img_result_wr),
	.IMG_RESULT(img_result),
	.IMG_SUM(img_sum),
	.IMG_Q_WR(img_q_wr),
	.IMG_Q_DI(img_q_di),
	.IMG_Q_ACK(img_q_ack),
	.ESP_UART_RX_DATA(8'h00),
	.ESP_UART_RX_WR(1'b0),
	.FLASHBOOT_START(1'b0),
	.FLASHBOOT_COREID(5'd0)
);

assign FT_SPI_CS_N = ft_spi_on ? ft_cs_n : 1'b1;
assign FT_SPI_SCK = ft_spi_on ? mcu_sck_ibufg : 1'b1;
assign FT_SPI_MOSI = ft_spi_on ? ft_mosi : 1'b1;
assign SD_CS_N = sd2_cs_n;
assign SD_DI = sd2_mosi;
assign SD_CLK = mcu_sck_ibufg;

// ------------------------------------------------------------------ soft switches

wire [17*8-1:0] sw;
kg_soft_switches #(.N(17)) soft_switches (
	.clk(clk_sys),
	.command(softsw_command),
	.regs(sw),
	.upd()
);
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

orionpro_system orion (
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
	.img_mounted(img_mounted),
	.img_size(img_size),
	.img_wp(img_wp),
	.img_data_wr(img_data_wr),
	.img_data_addr(img_data_addr),
	.img_data(img_data),
	.img_result_wr(img_result_wr),
	.img_result(img_result),
	.img_sum(img_sum),
	.img_q_wr(img_q_wr),
	.img_q_di(img_q_di),
	.img_q_ack(img_q_ack),
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

// the OSD commands of kg_mcu (clk_sys) into clk_pix: a word that changes is a command, it crosses
// through a fifo and comes out as a change again (as core-msx)
reg [15:0] osd_cmd_d = 16'd0;
always @(posedge clk_sys)
	osd_cmd_d <= osd_command;
wire osd_fifo_empty;
wire [15:0] osd_cmd_pix;
kg_async_fifo #(.DW(16), .AW(4)) osd_fifo (
	.wclk(clk_sys), .wreset(areset), .wr(osd_command != osd_cmd_d), .din(osd_command), .full(),
	.rclk(clk_pix), .rreset(areset), .rd(!osd_fifo_empty), .dout(osd_cmd_pix), .empty(osd_fifo_empty),
	.rcount()
);

// in the middle of 800 x 600: the counters start at the leading edge of the syncs, a step is two
// pixels / lines: the picture starts 216 pixels and 27 lines after them, the OSD (512 x 416) 144
// pixels and 92 lines into it. 720 x 576: the OSD at x 104, 236 pixels (118 steps) after hsync, and
// 124 lines (62 steps) after vsync
wire [23:0] osd_rgb;
kg_osd_overlay #(.H_DIV4_WIDTH(1100), .V_OFFSET_IN(1), .H_OFFSET_IN(1)) osd (
	.clk(clk_pix),
	.rgb_i(video_rgb),
	.rgb_o(osd_rgb),
	.hsync_i(video_hs),
	.vsync_i(video_vs),
	.v_offset(pal ? 11'd62 : 11'd59),
	.h_offset(pal ? 11'd118 : 11'd180),
	.osd_command(osd_cmd_pix)
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
	.vsync(pal ? ~video_vs : video_vs),
	.hsync(pal ? ~video_hs : video_hs),
	.de(video_de),
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
