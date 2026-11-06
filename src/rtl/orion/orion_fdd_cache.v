`timescale 1ns / 1ps
`default_nettype wire

/*
 orion_fdd_cache.v (msx_fdd_cache.v of karabas-go-core-msx; SLOT is the image slot of img_sdc)

 The disk image in the SRAM: the sector interface of the MiSTer wd1793 (sd_rd / sd_wr / sd_lba,
 sd_ack, sd_buff_*) served from a copy of the image in the SRAM (aux port of orion_sram, BASE up),
 which fills from img_sdc of the modules (the file mounter of the mcu, its index 0) in the
 background.

 Why: the mcu answers a sector in 5-15 ms, and up to 200 ms when its main loop stalls or an
 answer is lost (img_sdc then asks again). That is the time of a real drive (a turn is 200 ms),
 but every sector costs it again. With the copy, a sector the FDC asks for is in its buffer in
 about 100 us.

 - mount (img_mounted, a clock): the valid map (one bit per sector, MAXSEC) is cleared, the fill
   starts at sector 0 (an image of 800 KB: 1600 sectors, about 16 s at 10 ms each; the machine runs
   meanwhile). A sector the mcu sends while a new image is mounted is dropped;
 - fill: the sectors in order, each one that is not valid: img_sdc read, the bytes into a buffer
   of a sector, then into the SRAM, then valid;
 - read of the FDC: a valid sector is copied from the SRAM into the buffer of the FDC; else it is
   read from the mcu at once (after the request of the fill in flight, if any) and goes into the
   buffer of the FDC and the SRAM. A sector past the image (or a read that failed: 512 zero bytes
   from img_sdc) goes to the FDC only;
 - write of the FDC: its buffer is copied into the SRAM (the sector is valid then), then written
   to the image through img_sdc (img_sdc copies it out of the buffer of the FDC), sd_ack ends when
   the mcu has it (write-through: the image on the card is always the same as the SRAM).
 sd_ack is up from the start of the work on a request to its end (the FDC samples it at the CPU
 clock enable; the shortest, a copy from the SRAM, is about 4000 clocks).
*/

module orion_fdd_cache #(
	parameter [21:0] BASE = 22'h300000,  // the SRAM bytes of the image (MAXSEC * 512)
	parameter MAXSEC = 1640,              // 820 KB: an Orion disk of 82 tracks
	parameter [2:0] SLOT = 3'd0
) (
	input wire clk,

	// img_sdc: the image of slot 0
	input wire img_mounted,
	input wire [31:0] img_size,

	// wd1793
	input wire sd_rd,
	input wire sd_wr,
	input wire [31:0] sd_lba,
	output reg sd_ack = 1'b0,
	output wire [8:0] sd_buff_addr,
	output reg [7:0] sd_buff_dout = 8'd0,
	output reg sd_buff_wr = 1'b0,
	input wire [7:0] sd_buff_din,

	// img_sdc, index 0
	output reg sdc_rd = 1'b0,
	output reg sdc_wr = 1'b0,
	output reg [31:0] sdc_sector = 32'd0,
	input wire sdc_busy,
	input wire sdc_done,
	input wire sdc_error,
	input wire [2:0] sdc_slot,
	input wire sdc_byte_in_strobe,
	input wire [8:0] sdc_byte_addr,
	input wire [7:0] sdc_byte_in_data,
	output wire [7:0] sdc_byte_out_data,

	input wire pause,           // no background fill now (a CAS file goes to the SRAM through the same port)

	// SRAM, aux port of orion_sram
	output reg aux_req = 1'b0,
	output reg aux_we = 1'b0,
	output reg [21:0] aux_addr = 22'd0,
	output reg [7:0] aux_din = 8'd0,
	input wire aux_ack,
	input wire [7:0] aux_dout,

	output wire filling,        // the fill is not complete
	output wire [10:0] filled   // the sectors done by the fill (its position)
);

localparam S_IDLE = 4'd0, S_CLEAR = 4'd1, S_CHECK = 4'd2, S_CHECK2 = 4'd3, S_FETCH = 4'd4,
	S_FETCH_WAIT = 4'd5, S_BUF = 4'd6, S_BUF2 = 4'd7, S_OUT = 4'd8, S_IN = 4'd9, S_IN2 = 4'd10,
	S_WT = 4'd11, S_WT_WAIT = 4'd12, S_END = 4'd13;
reg [3:0] state = S_IDLE;

wire mine = sdc_slot == SLOT;

// ---------------- the valid map
reg [10:0] v_addr = 11'd0;
reg v_we = 1'b0, v_din = 1'b0;
wire v_q;
kg_spram #(.DW(1), .AW(11)) vmap (.clk(clk), .en(1'b1), .we(v_we), .addr(v_addr), .din(v_din), .dout(v_q));

// ---------------- the buffer of a sector from the mcu
reg [8:0] b_raddr = 9'd0;
wire [7:0] b_q;
kg_sdpram #(.DW(8), .AW(9)) sbuf (
	.clka(clk), .wea(sdc_byte_in_strobe && mine && state == S_FETCH_WAIT), .addra(sdc_byte_addr),
	.dina(sdc_byte_in_data),
	.clkb(clk), .enb(1'b1), .addrb(b_raddr), .doutb(b_q)
);

// ---------------- state
reg [10:0] nsec = 11'd0;        // sectors of the image (MAXSEC at most)
reg clear_pending = 1'b0;
reg [10:0] fill_ptr = 11'd0;
reg [31:0] lba = 32'd0;          // the sector of the work in progress
reg for_fdc = 1'b0;              // the work answers a request of the FDC
reg fdc_write = 1'b0;
reg drop = 1'b0;                 // the image changed during a fetch
reg cacheable = 1'b0;            // lba < nsec
reg failed = 1'b0;
reg [9:0] cnt = 10'd0;           // byte of a copy (512 = done)
reg [8:0] fdc_addr = 9'd0;

assign sd_buff_addr = (state == S_WT || state == S_WT_WAIT) ? sdc_byte_addr : fdc_addr;
assign sdc_byte_out_data = sd_buff_din;
assign filling = fill_ptr < nsec;
assign filled = fill_ptr;

wire [21:0] sec_base = BASE + { lba[10:0], 9'd0 };
wire [23:0] img_sec = img_size[31:9] + { 23'd0, img_size[8:0] != 9'd0 };
wire [10:0] max_sec = MAXSEC;
wire fdc_req = sd_rd || sd_wr;

always @(posedge clk) begin
	v_we <= 1'b0;
	sd_buff_wr <= 1'b0;

	// a new image: the work in progress (not in S_IDLE) neither writes the SRAM, nor sets a valid
	// bit, nor moves the fill, nor writes to the mcu (the image is another one now); the FDC still
	// gets its answer
	if (img_mounted) begin
		nsec <= (img_sec > MAXSEC) ? max_sec : img_sec[10:0];
		clear_pending <= 1'b1;
		fill_ptr <= 11'd0;
		if (state != S_IDLE)
			drop <= 1'b1;
	end

	case (state)
		S_IDLE: begin
			drop <= 1'b0;
			if (clear_pending && !img_mounted) begin
				clear_pending <= 1'b0;
				v_addr <= 11'd0;
				v_din <= 1'b0;
				v_we <= 1'b1;
				state <= S_CLEAR;
			end
			else if (fdc_req && !img_mounted) begin
				lba <= sd_lba;
				fdc_write <= !sd_rd;
				for_fdc <= 1'b1;
				v_addr <= sd_lba[10:0];
				cacheable <= sd_lba < { 21'd0, nsec };
				sd_ack <= 1'b1;
				state <= S_CHECK;
			end
			else if (fill_ptr < nsec && !img_mounted && !pause) begin
				lba <= { 21'd0, fill_ptr };
				for_fdc <= 1'b0;
				fdc_write <= 1'b0;
				v_addr <= fill_ptr;
				cacheable <= 1'b1;
				state <= S_CHECK;
			end
		end

		S_CLEAR: begin
			v_addr <= v_addr + 11'd1;
			v_we <= 1'b1;
			if (v_addr == 11'd2047) begin
				v_we <= 1'b0;
				state <= S_IDLE;
			end
		end

		S_CHECK: state <= S_CHECK2;  // the valid bit of v_addr comes now

		S_CHECK2:
			if (fdc_write) begin
				fdc_addr <= 9'd0;
				cnt <= 10'd0;
				state <= cacheable ? S_IN : S_WT;
			end
			else if (cacheable && v_q) begin
				if (for_fdc) begin
					cnt <= 10'd0;
					fdc_addr <= 9'd0;
					state <= S_OUT;
				end
				else begin
					if (!drop)
						fill_ptr <= fill_ptr + 11'd1;
					state <= S_IDLE;
				end
			end
			else
				state <= S_FETCH;

		// a read from the mcu
		S_FETCH: begin
			sdc_rd <= 1'b1;
			sdc_sector <= lba;
			if (sdc_busy && mine && sdc_rd) begin
				sdc_rd <= 1'b0;
				state <= S_FETCH_WAIT;
			end
		end

		S_FETCH_WAIT:
			if (sdc_done && mine) begin
				failed <= sdc_error;
				cnt <= 10'd0;
				b_raddr <= 9'd0;
				state <= S_BUF;
			end

		// the sector from the buffer into the SRAM (cacheable, not failed, not dropped) and the FDC
		S_BUF: state <= S_BUF2;  // b_q of b_raddr comes now
		S_BUF2:
			if (cnt == 10'd512) begin
				if (cacheable && !failed && !drop) begin
					v_addr <= lba[10:0];
					v_din <= 1'b1;
					v_we <= 1'b1;
				end
				if (!for_fdc && !drop)
					fill_ptr <= fill_ptr + 11'd1;
				state <= S_END;
			end
			else if (!aux_req) begin
				if (for_fdc) begin
					fdc_addr <= cnt[8:0];
					sd_buff_dout <= b_q;
					sd_buff_wr <= 1'b1;
				end
				if (cacheable && !failed && !drop) begin
					aux_addr <= sec_base + { 13'd0, cnt[8:0] };
					aux_din <= b_q;
					aux_we <= 1'b1;
					aux_req <= 1'b1;
				end
				else begin
					cnt <= cnt + 10'd1;
					b_raddr <= cnt[8:0] + 9'd1;
					state <= S_BUF;
				end
			end
			else if (aux_ack) begin
				aux_req <= 1'b0;
				cnt <= cnt + 10'd1;
				b_raddr <= cnt[8:0] + 9'd1;
				state <= S_BUF;
			end

		// a valid sector from the SRAM into the FDC
		S_OUT:
			if (cnt == 10'd512)
				state <= S_END;
			else if (!aux_req) begin
				aux_addr <= sec_base + { 13'd0, cnt[8:0] };
				aux_we <= 1'b0;
				aux_req <= 1'b1;
			end
			else if (aux_ack) begin
				aux_req <= 1'b0;
				fdc_addr <= cnt[8:0];
				sd_buff_dout <= aux_dout;
				sd_buff_wr <= 1'b1;
				cnt <= cnt + 10'd1;
			end

		// a write of the FDC: its buffer into the SRAM (sd_buff_din a clock after fdc_addr), then the mcu
		S_IN: state <= S_IN2;
		S_IN2:
			if (cnt == 10'd512) begin
				v_addr <= lba[10:0];
				v_din <= 1'b1;
				v_we <= !drop;
				state <= drop ? S_END : S_WT;
			end
			else if (!aux_req) begin
				aux_addr <= sec_base + { 13'd0, cnt[8:0] };
				aux_din <= sd_buff_din;
				aux_we <= 1'b1;
				aux_req <= 1'b1;
			end
			else if (aux_ack) begin
				aux_req <= 1'b0;
				cnt <= cnt + 10'd1;
				fdc_addr <= cnt[8:0] + 9'd1;
				state <= S_IN;
			end

		S_WT: begin
			sdc_wr <= 1'b1;
			sdc_sector <= lba;
			if (sdc_busy && mine && sdc_wr) begin
				sdc_wr <= 1'b0;
				state <= S_WT_WAIT;
			end
		end
		S_WT_WAIT:
			if (sdc_done && mine)
				state <= S_END;

		default: begin // S_END
			if (for_fdc)
				sd_ack <= 1'b0;
			for_fdc <= 1'b0;
			state <= S_IDLE;
		end
	endcase
end

endmodule
