`timescale 1ns / 1ps
`default_nettype wire

/*
 orion_loader.v

 What the firmware loads, one master on the aux port of orion_sram. The ROM loader writes at
 rom_addr. An FL item writes by the slot of file_slot (the mcu writes a byte in ten clocks or less
 often, the slot is right from the first byte on; the machine is in reset meanwhile):
   slot 0  a ROM disk at 200000, 256 KB
   slot 1  an ORDOS file (.ord, .bru) appended to the RAM disk B:
   slot 2  ROM2 at 3E0000, 64 KB
   slot 3  ROM1 at 3F0000, 8 KB

 Once after the first ROMs of the core the RAM is cleared, the machine in reset (clearing, some 300
 ms): the shell of ROM2 takes what it finds in page 1 for a RAM disk, and what another core left
 there sends it astray (a stack through the screen, no keyboard). A Reset of the machine does not clear.

 The RAM disk is page 1: records of a 16-byte header (name 8, load address 2, size 2, 4 reserved)
 and the data, an FF after the last one. Once per frame (tick) the walker follows the records to
 find their end; a first byte that is no ASCII character ends them too (a page never written).
 A file is written at that end, only its record (a .bru has padding after it), then the FF, at
 the end of the load. The records stop below C000: above is the colour plane of the screens.
*/

module orion_loader (
	input wire clk,

	input wire rom_active,
	input wire [21:0] rom_addr,
	input wire [7:0] rom_data,
	input wire rom_wr,

	input wire file_active,
	input wire [7:0] file_slot,
	input wire [31:0] file_addr,
	input wire [7:0] file_data,
	input wire file_wr,

	input wire tick,
	output wire clearing,

	output wire aux_req,
	output wire aux_we,
	output reg [21:0] aux_addr = 22'd0,
	output reg [7:0] aux_din = 8'd0,
	input wire aux_ack,
	input wire [7:0] aux_dout
);

function [21:0] page1;        // a byte of page 1
	input [15:0] a;
	page1 = { 5'd0, a, 1'b1 };
endfunction

localparam [15:0] LIMIT = 16'hC000;

// a write waits here for the port
reg pend = 1'b0;
reg [21:0] pend_addr = 22'd0;
reg [7:0] pend_data = 8'd0;

// the file
wire ord_slot = file_slot == 8'd1;
wire [31:0] rec_i = file_addr;          // the byte of the record
reg [15:0] rec_end = 16'd0;             // the walker: the end of the records
reg [7:0] size_lo = 8'd0;
reg [16:0] rec_len = 17'd65535;         // of this record, known at byte 12
reg [16:0] rec_n = 17'd0;               // written so far
reg ord_load = 1'b0;
reg active_d = 1'b0;

wire [16:0] rec_t = { 1'b0, rec_end } + rec_n;
wire room = rec_t < { 1'b0, LIMIT } && rec_n < rec_len;

// the walker
localparam W_IDLE = 2'd0, W_NAME = 2'd1, W_LO = 2'd2, W_HI = 2'd3;
reg [1:0] w = W_IDLE;
reg [15:0] wp = 16'd0;
reg [7:0] w_lo = 8'd0;
wire [16:0] wp_next = { 1'b0, wp } + 17'd16 + { 1'b0, aux_dout, w_lo };

// the port
localparam C_NONE = 2'd0, C_WRITE = 2'd1, C_WALK = 2'd2;
reg [1:0] cur = C_NONE;
assign aux_req = cur != C_NONE;
assign aux_we = cur == C_WRITE;

wire busy = file_active | rom_active;

reg rom_d = 1'b0;
reg clr = 1'b0, clr_done = 1'b0;
reg [20:0] clr_a = 21'd0;
assign clearing = clr;

always @(posedge clk) begin
	active_d <= file_active;
	rom_d <= rom_active;
	if (rom_d && !rom_active && !clr_done) begin
		clr <= 1'b1;
		clr_done <= 1'b1;
	end

	// the writes
	if (rom_wr) begin
		pend <= 1'b1;
		pend_addr <= rom_addr;
		pend_data <= rom_data;
	end
	else if (file_wr) begin
		if (file_slot == 8'd0) begin
			pend <= 1'b1;
			pend_addr <= { 4'b1000, file_addr[17:0] };
			pend_data <= file_data;
		end
		else if (file_slot == 8'd2) begin
			pend <= 1'b1;
			pend_addr <= { 6'b111110, file_addr[15:0] };
			pend_data <= file_data;
		end
		else if (file_slot == 8'd3) begin
			pend <= 1'b1;
			pend_addr <= { 9'b111111000, file_addr[12:0] };
			pend_data <= file_data;
		end
		else if (ord_slot) begin
			ord_load <= 1'b1;
			if (rec_i == 32'd10)
				size_lo <= file_data;
			if (rec_i == 32'd11)
				rec_len <= 17'd16 + { 1'b0, file_data, size_lo };
			if (room) begin
				pend <= 1'b1;
				pend_addr <= page1(rec_t[15:0]);
				pend_data <= file_data;
				rec_n <= rec_n + 17'd1;
			end
		end
	end
	else if (active_d && !file_active && ord_load) begin
		// the end of the file: the FF after the record
		ord_load <= 1'b0;
		pend <= 1'b1;
		pend_addr <= page1(rec_t[15:0]);
		pend_data <= 8'hFF;
	end
	if (!file_active) begin
		rec_n <= 17'd0;
		rec_len <= 17'd65535;
	end

	// the port
	if (aux_ack) begin
		cur <= C_NONE;
		if (cur == C_WALK) begin
			case (w)
				W_NAME:
					if (aux_dout < 8'h20 || aux_dout >= 8'h7F) begin
						rec_end <= wp;
						w <= W_IDLE;
					end
					else
						w <= W_LO;
				W_LO: begin
					w_lo <= aux_dout;
					w <= W_HI;
				end
				W_HI:
					if (wp_next >= { 1'b0, LIMIT }) begin
						rec_end <= wp;
						w <= W_IDLE;
					end
					else begin
						wp <= wp_next[15:0];
						w <= W_NAME;
					end
				default: w <= W_IDLE;
			endcase
		end
	end
	else if (cur == C_NONE) begin
		if (pend) begin
			cur <= C_WRITE;
			aux_addr <= pend_addr;
			aux_din <= pend_data;
			if (!rom_wr && !file_wr)
				pend <= 1'b0;
		end
		else if (clr && !busy) begin
			cur <= C_WRITE;
			aux_addr <= { 1'b0, clr_a };
			aux_din <= 8'd0;
			clr_a <= clr_a + 21'd1;
			if (clr_a == 21'h1FFFFF)
				clr <= 1'b0;
		end
		else if (w != W_IDLE && !busy) begin
			cur <= C_WALK;
			aux_addr <= page1(w == W_NAME ? wp : w == W_LO ? wp + 16'd10 : wp + 16'd11);
		end
	end

	if (busy)
		w <= W_IDLE;
	else if (tick && w == W_IDLE) begin
		w <= W_NAME;
		wp <= 16'd0;
	end
end

endmodule
