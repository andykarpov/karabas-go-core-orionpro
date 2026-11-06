`timescale 1ns / 1ps
`default_nettype wire

// The SD card of the Orion-2010 (F762 / F763, the MSX scheme of OriZEmu modSD and vga_test.vhd of
// orion2010-zxuno) on a disk image of the file mounter. The card itself is that of nextor_sd.v of
// karabas-go-core-msx (a state machine on bytes: CMD0/1/8/9/10/12/16/17/18/24/25/55/58, ACMD23/41,
// SDHC), copied from "the sector buffer" on; here the SPI is bit by bit, as the Orion-2010 has it:
// - F762 write: D2 = 1 selects the card;
// - F763 write: MOSI = D7 and one clock of SCK: the write drops it, the next read cycle of the CPU
//   (the fetch of the next instruction) raises it, so the card takes MOSI right after the write;
// - a read of F763 gives the shift register of MISO, filled at the falling edges of SCK, and MISO
//   now in D0: after 8 writes it is the byte of the card. A read does not clock.
// The card sends MSB first and changes MISO after a falling edge (SPI mode 0).
module orion_sd (
	input wire clk,
	input wire reset,
	input wire cs_wr,             // a write of F762 (one clock)
	input wire d_wr,              // a write of F763 (one clock)
	input wire [7:0] din,
	output wire [7:0] dout,
	// the image (img_sdc)
	input wire img_mounted,       // a pulse: img_size is the new size (0 = none)
	input wire [31:0] img_size,
	output reg hd_rd = 1'b0,
	output reg hd_wr = 1'b0,
	output reg [31:0] hd_lba = 32'd0,
	input wire hd_busy,           // img_sdc took the request (of this card)
	input wire hd_done,           // its end (of this card)
	input wire hd_byte_in_strobe, // a byte of a read sector (of this card)
	input wire [8:0] hd_byte_addr,
	input wire [7:0] hd_byte_in_data,
	output wire [7:0] hd_byte_out_data
);

// ------------------------------------------------------------------ the bits

reg cs_n = 1'b1;
reg rise = 1'b0;              // the rising edge after a write
reg ready_l = 1'b0;           // ready when the byte was loaded: the token went out in it
reg mosi = 1'b1;
reg [2:0] bitcnt = 3'd0;      // rising edges of this byte
reg [7:0] tx_sh = 8'hFF;
reg [7:0] out_sh = 8'hFF;     // the byte of the card, its bit 7 is MISO
reg [7:0] miso_buf = 8'hFF;
reg xfer = 1'b0;              // one clock: the byte tx is complete
reg [7:0] tx = 8'hFF;
reg [7:0] rx = 8'hFF;         // unused here (the byte of nextor_sd)
wire [7:0] out;
wire miso = cs_n ? 1'b1 : out_sh[7];

assign dout = { miso_buf[6:0], miso };

always @(posedge clk) begin
	xfer <= 1'b0;
	rise <= 1'b0;
	if (reset) begin
		cs_n <= 1'b1;
		bitcnt <= 3'd0;
		out_sh <= 8'hFF;
	end else begin
		if (cs_wr)
			cs_n <= ~din[2];
		if (d_wr) begin
			// the falling edge: the bit before goes into the shift register of MISO, the card shows
			// its next bit (the first bit of a byte: the byte the card gives in this exchange)
			mosi <= din[7];
			miso_buf <= { miso_buf[6:0], miso };
			if (bitcnt == 3'd0) begin
				out_sh <= cs_n ? 8'hFF : out;
				ready_l <= ready;
			end
			else
				out_sh <= { out_sh[6:0], 1'b1 };
			rise <= 1'b1;
		end
		if (rise) begin
			tx_sh <= { tx_sh[6:0], mosi };
			bitcnt <= bitcnt + 3'd1;
			if (bitcnt == 3'd7) begin
				tx <= { tx_sh[6:0], mosi };
				xfer <= 1'b1;
			end
		end
	end
end

// ------------------------------------------------------------------ the sector buffer

// the request to img_sdc: pending until its end; a request whose block nobody wants any more
// (CMD12, a deselect, a reset) is stale: its end is not taken as the data of a new one
reg pending = 1'b0;
reg stale = 1'b0;

// port a: the card (buf_addr), port b: img_sdc (a read sector in, a written one out). The bytes of
// a stale read are not taken: they would come over a block the CPU is writing (CMD12 after CMD18,
// then CMD24: the block read ahead arrives while the new one is written)
reg [8:0] buf_addr = 9'd0;    // the byte of the card (read: the next one out, write: the next one in)
wire [7:0] buf_q;
reg buf_we = 1'b0;
reg [7:0] buf_wd = 8'h00;
kg_tdpram #(.DW(8), .AW(9)) sector (
	.clka(clk), .ena(1'b1), .wea(buf_we), .addra(buf_addr), .dina(buf_wd), .douta(buf_q),
	.clkb(clk), .enb(1'b1), .web(hd_byte_in_strobe & ~stale), .addrb(hd_byte_addr), .dinb(hd_byte_in_data),
	.doutb(hd_byte_out_data)
);

// ------------------------------------------------------------------ the card

localparam S_IDLE = 4'd0, S_CMD = 4'd1, S_RESP = 4'd2, S_RD_WAIT = 4'd3, S_RD_DATA = 4'd4,
	S_RD_CRC = 4'd5, S_WR_TOKEN = 4'd6, S_WR_DATA = 4'd7, S_WR_CRC = 4'd8, S_WR_RESP = 4'd9,
	S_WR_BUSY = 4'd10;

reg [3:0] state = S_IDLE;
reg [5:0] cmd = 6'd0;
reg [31:0] arg = 32'd0;
reg [2:0] cnt = 3'd0;         // the bytes of a command
reg [4:0] ridx = 5'd0;        // the byte of a response
reg idle = 1'b1;              // the idle bit of R1 (until ACMD41 / CMD1)
reg app = 1'b0;               // CMD55 before: an ACMD
reg acmd = 1'b0;              // the command is an ACMD
reg multi = 1'b0;             // CMD18 / CMD25
reg crc1 = 1'b0;              // the first CRC byte of a block was there

reg ready = 1'b0;             // the block of the read is in the buffer / the write is done
reg want = 1'b0;              // a request to make when img_sdc is free of the stale one
reg want_wr = 1'b0;

// C_SIZE of the CSD (version 2): (size / 512 KB) - 1
reg [31:0] size = 32'd0;
always @(posedge clk)
	if (img_mounted)
		size <= img_size;
wire [21:0] c_size = size[31:19] == 13'd0 ? 22'd0 : { 9'd0, size[31:19] } - 22'd1;
// karabas: a standard capacity card (CSD version 1, byte addresses) for a host without HCS, as the
// SD Monitors of the Orion: READ_BL_LEN 9, C_SIZE_MULT 7 (units of 256 KB), 1 GB at most
reg sdsc = 1'b0;
wire [11:0] c_size1 = size[31:18] == 14'd0 ? 12'd0 : size[31:18] > 14'd4096 ? 12'd4095 : size[29:18] - 12'd1;

reg cmd_bad;
always @* begin
	case (cmd)
		6'd0, 6'd1, 6'd8, 6'd9, 6'd10, 6'd12, 6'd16, 6'd17, 6'd18, 6'd24, 6'd25, 6'd55, 6'd58: cmd_bad = 1'b0;
		default: cmd_bad = 1'b1;
	endcase
end
wire [7:0] r1 = { 5'd0, (acmd ? 1'b0 : cmd_bad), 1'b0, idle };

// the bytes of a response after R1 (ridx 1..): R7, OCR, the CSD / CID with their token and CRC
reg [7:0] resp;
reg [4:0] resp_len;           // the bytes of the response, R1 included
always @* begin
	resp = 8'hFF;
	resp_len = 5'd1;
	if (!acmd) case (cmd)
		6'd8: begin
			resp_len = 5'd5;
			case (ridx)
				5'd3: resp = { 4'd0, arg[11:8] };
				5'd4: resp = arg[7:0];
				default: resp = 8'h00;
			endcase
		end
		6'd58: begin
			resp_len = 5'd5;
			case (ridx)
				5'd1: resp = sdsc ? 8'h80 : 8'hC0;   // powered up, CCS (SDHC)
				5'd2: resp = 8'hFF;
				5'd3: resp = 8'h80;
				default: resp = 8'h00;
			endcase
		end
		6'd9: begin
			resp_len = 5'd20;
			case (ridx)
				5'd1: resp = 8'hFE;
				5'd2: resp = sdsc ? 8'h00 : 8'h40;   // CSD version 1 / 2
				5'd3: resp = 8'h0E;
				5'd4: resp = 8'h00;
				5'd5: resp = 8'h32;
				5'd6: resp = 8'h5B;
				5'd7: resp = 8'h59;   // READ_BL_LEN 9
				5'd8: resp = sdsc ? { 6'd0, c_size1[11:10] } : 8'h00;
				5'd9: resp = sdsc ? c_size1[9:2] : { 2'd0, c_size[21:16] };
				5'd10: resp = sdsc ? { c_size1[1:0], 6'h3F } : c_size[15:8];
				5'd11: resp = sdsc ? 8'hFF : c_size[7:0];  // C_SIZE_MULT 7
				5'd12: resp = sdsc ? 8'hFF : 8'h7F;
				5'd13: resp = 8'h80;
				5'd14: resp = 8'h0A;
				5'd15: resp = 8'h40;  // WRITE_BL_LEN 9
				5'd16: resp = 8'h00;
				5'd17: resp = 8'h01;
				default: resp = 8'hFF;
			endcase
		end
		6'd10: begin
			resp_len = 5'd20;
			case (ridx)
				5'd1: resp = 8'hFE;
				5'd2: resp = 8'h00;   // MID
				5'd3: resp = "K";     // OID
				5'd4: resp = "G";
				5'd5: resp = "M";     // PNM
				5'd6: resp = "S";
				5'd7: resp = "X";
				5'd8: resp = "H";
				5'd9: resp = "D";
				5'd10: resp = 8'h10;  // PRV 1.0
				5'd15: resp = 8'h01;  // MDT
				5'd16: resp = 8'h6A;
				5'd17: resp = 8'h01;
				5'd18, 5'd19: resp = 8'hFF;
				default: resp = 8'h00;
			endcase
		end
		default: ;
	endcase
end

// the byte the card gives in the exchange
reg [7:0] out_r;
assign out = out_r;
always @* begin
	case (state)
		S_RESP: out_r = ridx == 5'd0 ? r1 : resp;
		S_RD_WAIT: out_r = ready ? 8'hFE : 8'hFF;
		S_RD_DATA: out_r = buf_q;
		S_WR_RESP: out_r = 8'h05;
		S_WR_BUSY: out_r = ready ? 8'hFF : 8'h00;
		default: out_r = 8'hFF;
	endcase
end

wire is_cmd = tx[7:6] == 2'b01;

always @(posedge clk) begin
	buf_we <= 1'b0;
	// img_sdc
	if (hd_busy) begin
		hd_rd <= 1'b0;
		hd_wr <= 1'b0;
	end
	if (hd_done) begin
		pending <= 1'b0;
		if (!stale)
			ready <= 1'b1;
		stale <= 1'b0;
	end
	if (want && !pending) begin
		want <= 1'b0;
		pending <= 1'b1;
		ready <= 1'b0;
		if (want_wr) hd_wr <= 1'b1; else hd_rd <= 1'b1;
	end

	if (reset) begin
		// the machine reset: the card is idle (the driver starts with CMD0 again)
		state <= S_IDLE;
		if (pending && !ready)
			stale <= 1'b1;
		want <= 1'b0;
		rx <= 8'hFF;
	end else if (xfer) begin
		rx <= cs_n ? 8'hFF : out;
		if (cs_n) begin
			// deselected: the card drops what it was doing
			state <= S_IDLE;
			if (pending && !ready)
				stale <= 1'b1;
			want <= 1'b0;
		end else case (state)
			S_IDLE, S_RD_WAIT: begin
				if (state == S_RD_WAIT && ready_l && !is_cmd) begin
					// the token went out: the data from byte 0 (buf_q)
					state <= S_RD_DATA;
				end else if (is_cmd) begin
					if (state == S_RD_WAIT) begin
						// CMD12 in a multiple block read: the block on its way is not wanted
						if (pending)
							stale <= 1'b1;
						want <= 1'b0;
					end
					cmd <= tx[5:0];
					acmd <= app;
					app <= 1'b0;
					cnt <= 3'd1;
					state <= S_CMD;
				end
			end
			S_CMD: begin
				if (cnt <= 3'd4)
					arg <= { arg[23:0], tx };
				if (cnt == 3'd5) begin
					// the CRC: the command is complete
					ridx <= 5'd0;
					state <= S_RESP;
					if (!acmd) case (cmd)
						6'd0: idle <= 1'b1;
						6'd1: begin idle <= 1'b0; sdsc <= 1'b1; end
						6'd55: app <= 1'b1;
						default: ;
					endcase
					else if (cmd == 6'd41) begin
						idle <= 1'b0;
						sdsc <= !arg[30];  // a host without HCS gets a standard capacity card
					end
				end
				cnt <= cnt + 3'd1;
			end
			S_RESP: begin
				if (ridx == resp_len - 5'd1) begin
					state <= S_IDLE;
					if (!acmd && (cmd == 6'd17 || cmd == 6'd18)) begin
						hd_lba <= sdsc ? { 9'd0, arg[31:9] } : arg;
						multi <= cmd == 6'd18;
						want <= 1'b1;
						want_wr <= 1'b0;
						ready <= 1'b0;
						buf_addr <= 9'd0;
						state <= S_RD_WAIT;
					end
					if (!acmd && (cmd == 6'd24 || cmd == 6'd25)) begin
						hd_lba <= sdsc ? { 9'd0, arg[31:9] } : arg;
						multi <= cmd == 6'd25;
						state <= S_WR_TOKEN;
					end
				end
				ridx <= ridx + 5'd1;
			end
			S_RD_DATA: begin
				buf_addr <= buf_addr + 9'd1;
				if (buf_addr == 9'd511) begin
					// the last byte went out: the CRC
					crc1 <= 1'b0;
					state <= S_RD_CRC;
				end
			end
			S_RD_CRC: begin
				crc1 <= 1'b1;
				if (crc1) begin
					if (multi) begin
						hd_lba <= hd_lba + 32'd1;
						want <= 1'b1;
						want_wr <= 1'b0;
						ready <= 1'b0;
						buf_addr <= 9'd0;
						state <= S_RD_WAIT;
					end else
						state <= S_IDLE;
				end
			end
			S_WR_TOKEN: begin
				if (tx == 8'hFE || (multi && tx == 8'hFC)) begin
					buf_addr <= 9'd0;
					state <= S_WR_DATA;
				end else if (multi && tx == 8'hFD)
					state <= S_IDLE;
				else if (is_cmd) begin
					cmd <= tx[5:0];
					acmd <= app;
					app <= 1'b0;
					cnt <= 3'd1;
					state <= S_CMD;
				end
			end
			S_WR_DATA: begin
				buf_wd <= tx;
				buf_we <= 1'b1;
				if (buf_addr == 9'd511) begin
					crc1 <= 1'b0;
					state <= S_WR_CRC;
				end
			end
			S_WR_CRC: begin
				crc1 <= 1'b1;
				if (crc1) begin
					want <= 1'b1;
					want_wr <= 1'b1;
					ready <= 1'b0;
					state <= S_WR_RESP;
				end
			end
			S_WR_RESP: state <= S_WR_BUSY;
			S_WR_BUSY: begin
				if (ready) begin
					hd_lba <= hd_lba + 32'd1;
					state <= multi ? S_WR_TOKEN : S_IDLE;
				end
			end
			default: state <= S_IDLE;
		endcase
	end
	// the byte written above goes to buf_addr, then the address moves on
	if (buf_we)
		buf_addr <= buf_addr + 9'd1;
end

endmodule
