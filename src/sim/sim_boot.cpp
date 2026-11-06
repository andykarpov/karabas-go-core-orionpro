// sim_boot: tb_boot (orion_system + SRAM model) under verilator.
//
//   sim_boot --rom FILE:ADDR ... [--z80] [--speed N] [--ram N] [--ms7007] [--ms N] [--ppm OUT]
//            [--key MS:CODE,CODE..] ... [--file MS:SLOT:FILE] ... [--expect ADDR:VALUE] ...
//            [--disk FILE] [--hdd FILE] [--save-disk OUT]
//
// The ROMs go in through the ROM loader (one byte every 12 clocks). The machine then runs N ms of
// its time. --ppm writes the last output frame, 800 x 600. --key sends PS/2 set 2 codes (hex) at
// a time in ms, 100 us apart. --file loads a file through the file loader of an FL slot at a time
// in ms. --expect checks a byte of the SRAM model at the end (ADDR its byte address, VALUE or
// >VALUE), a failure makes the exit code 1. Prints a checksum of the frame and how many pixels are
// not black. --disk: the image of disk A (F slot 4) on a model of the file mounter of the firmware,
// mounted at the start; --save-disk writes it back at the end.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include "Vtb_boot.h"
#include "verilated.h"

static Vtb_boot *top;
static uint64_t clks = 0;

static void mcu_clk();
static std::vector<uint8_t> *disk_p;

static void tick() {
	top->clk = 0; top->eval();
	if (disk_p) mcu_clk();
	top->clk = 1; top->eval();
	clks++;
}

// ---- the file mounter of the firmware (docs/protocol.md section 6), as core-msx sim_sys: a read is
// answered with 512 bytes (one per 11 clk), the sum, the result; a write is taken with its bytes.
static std::vector<uint8_t> disks[8];       // by slot: 4 --disk, 6 --hdd
#define disk disks[mcu_slot]
static int mcu_slot = 4;
static uint32_t mcu_lba = 0;
static int mcu_op = 0, mcu_pos = -1, mcu_gap = 0, mcu_wcnt = 0, mcu_bank = 0, mcu_wsum_parts = 0;
static int64_t mcu_wait = -1;
static uint8_t mcu_wbuf[512];
static uint16_t mcu_wsum = 0;
static int mount_wait = 2000, mount_hd = 0;
static int disk_reads = 0, disk_writes = 0;

static void mcu_clk() {
	top->img_q_ack = 0;
	top->img_data_wr = 0;
	top->img_result_wr = 0;
	top->img_mounted = 0;
	if (mount_wait > 0 && --mount_wait == 0) {
		top->img_size = disks[4].size();
		top->img_mounted = 1 << 4;
		mount_hd = 2000;
	}
	if (mount_hd > 0 && --mount_hd == 0 && !disks[6].empty()) {
		top->img_size = disks[6].size();
		top->img_mounted = 1 << 6;
	}
	if (top->img_q_wr && !top->img_q_ack) {
		uint32_t w = top->img_q_di;
		uint8_t c = w >> 16, a = w >> 8, d = w;
		top->img_q_ack = 1;
		if (c == 0x42) {
			if (a == 0) mcu_lba = 0;
			mcu_lba |= (uint32_t)d << (8 * a);
		}
		else if (c == 0x43) {
			mcu_op = d;
			mcu_slot = a;
			mcu_wcnt = 0; mcu_wsum_parts = 0; mcu_wsum = 0;
			if (d == 1) { mcu_wait = 4000; disk_reads++; }
		}
		else if (c == 0x44 && mcu_op == 2) {
			if (a == 0) mcu_bank = d & 1;
			else if (a == 0x10) { mcu_wsum = (mcu_wsum & 0xFF00) | d; mcu_wsum_parts++; }
			else if (a == 0x11) {
				mcu_wsum = (mcu_wsum & 0x00FF) | (d << 8); mcu_wsum_parts++;
				if (mcu_wsum_parts == 2) {
					if (mcu_lba * 512 + 512 <= disk.size()) memcpy(&disk[mcu_lba * 512], mcu_wbuf, 512);
					disk_writes++;
					mcu_op = 0;
					mcu_wait = 4000;
				}
			}
		}
		else if (c == 0x45 && mcu_op == 2) {
			mcu_wbuf[mcu_bank * 256 + a] = d;
			mcu_wcnt++;
		}
	}
	if (mcu_wait > 0) mcu_wait--;
	else if (mcu_wait == 0) {
		mcu_wait = -1;
		if (mcu_op == 1) { mcu_pos = 0; mcu_gap = 0; }
		else { top->img_result = 1; top->img_result_wr = 1; }
	}
	if (mcu_pos >= 0 && ++mcu_gap == 11) {
		mcu_gap = 0;
		if (mcu_pos < 512) {
			size_t o = mcu_lba * 512ull + mcu_pos;
			uint8_t b = o < disk.size() ? disk[o] : 0;
			static uint16_t sum;
			if (mcu_pos == 0) sum = 0;
			sum += b;
			top->img_data_addr = mcu_pos;
			top->img_data = b;
			top->img_data_wr = 1;
			top->img_sum = sum;
			mcu_pos++;
		}
		else {
			mcu_pos = -1;
			mcu_op = 0;
			top->img_result = 1;
			top->img_result_wr = 1;
		}
	}
}

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	top = new Vtb_boot;
	std::vector<std::pair<std::string, uint32_t>> roms;
	struct Key { uint64_t at; int code; };
	std::vector<Key> keys;
	struct Fl { uint64_t at; int slot; std::string name; };
	std::vector<Fl> files;
	struct Ex { uint32_t a; int v; bool gt; };
	std::vector<Ex> expects;
	int speed = 0, ram = 1;
	const char *save_disk = nullptr;
	bool ms7007 = false;
	int ms = 1000;
	const char *ppm = nullptr;
	bool z80 = false;
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--rom")) {
			std::string s = argv[++i];
			size_t c = s.rfind(':');
			roms.push_back({ s.substr(0, c), (uint32_t)strtoul(s.c_str() + c + 1, nullptr, 0) });
		}
		else if (!strcmp(argv[i], "--z80")) z80 = true;
		else if (!strcmp(argv[i], "--key")) {
			char *p = argv[++i];
			uint64_t at = strtoul(p, &p, 10) * 40000;
			while (*p == ':' || *p == ',') { keys.push_back({ at, (int)strtoul(p + 1, &p, 16) }); at += 4000; }
		}
		else if (!strcmp(argv[i], "--disk") || !strcmp(argv[i], "--hdd")) {
			std::vector<uint8_t> &d = disks[argv[i][2] == 'd' && argv[i][3] == 'i' ? 4 : 6];
			FILE *f = fopen(argv[++i], "rb");
			if (!f) { perror(argv[i]); return 2; }
			fseek(f, 0, SEEK_END); d.resize(ftell(f)); fseek(f, 0, SEEK_SET);
			if (fread(d.data(), 1, d.size(), f) != d.size()) return 2;
			fclose(f);
		}
		else if (!strcmp(argv[i], "--save-disk")) save_disk = argv[++i];
		else if (!strcmp(argv[i], "--speed")) speed = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--ram")) ram = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--ms7007")) ms7007 = true;
		else if (!strcmp(argv[i], "--file")) {
			char *p = argv[++i];
			uint64_t at = strtoul(p, &p, 10) * 40000;
			int sl = strtoul(p + 1, &p, 10);
			files.push_back({ at, sl, p + 1 });
		}
		else if (!strcmp(argv[i], "--expect")) {
			char *p = argv[++i];
			uint32_t ad = strtoul(p, &p, 0);
			bool gt = p[1] == '>';
			expects.push_back({ ad, (int)strtoul(p + 1 + gt, nullptr, 0), gt });
		}
		else if (!strcmp(argv[i], "--ms")) ms = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--ppm")) ppm = argv[++i];
		else if (argv[i][0] != '+') { fprintf(stderr, "bad option %s\n", argv[i]); return 2; }
	}
	top->img_q_ack = 0; top->img_data_wr = 0; top->img_result_wr = 0; top->img_mounted = 0;
	if (!disks[4].empty() || !disks[6].empty()) disk_p = &disks[4];
	top->cpu_z80 = z80; top->cpu_speed = speed; top->ram_size = ram; top->kb_ms7007 = ms7007;
	top->file_active = 0; top->file_wr = 0; top->file_slot = 0; top->file_addr = 0;
	top->reset = 1; top->rom_active = 0; top->rom_wr = 0;
	top->kb_scancode = 0; top->kb_scancode_upd = 0;
	for (int i = 0; i < 400; i++) tick();
	top->reset = 0; top->rom_active = 1;
	for (auto &r : roms) {
		FILE *f = fopen(r.first.c_str(), "rb");
		if (!f) { perror(r.first.c_str()); return 2; }
		int c; uint32_t a = r.second;
		while ((c = fgetc(f)) != EOF) {
			top->rom_addr = a++; top->rom_data = c; top->rom_wr = 1; tick();
			top->rom_wr = 0;
			for (int i = 0; i < 11; i++) tick();
		}
		fclose(f);
	}
	for (int i = 0; i < 40; i++) tick();
	top->rom_active = 0;
	uint64_t start = clks, end = clks + (uint64_t)ms * 40000;
	int beeps = 0, prev = 0;
	std::vector<uint8_t> frame(800 * 600 * 3), last(800 * 600 * 3);
	int fx = 0, fy = 0, frames = 0, prev_de = 0, prev_vs = 0;
	size_t kn = 0;
	size_t fn = 0;
	FILE *ff = nullptr; uint32_t fa = 0; int fgap = 0, fstate = 0;
	while (clks < end) {
		tick();
		// the firmware order: active, then the slot, then the bytes
		if (!ff && fn < files.size() && clks - start >= files[fn].at) {
			ff = fopen(files[fn].name.c_str(), "rb");
			if (!ff) { perror(files[fn].name.c_str()); return 2; }
			top->file_active = 1; fstate = 400; fa = 0;
		}
		else if (ff) {
			top->file_wr = 0;
			if (fstate > 0) { if (--fstate == 200) top->file_slot = files[fn].slot; }
			else if (++fgap == 12) {
				fgap = 0;
				int c = fgetc(ff);
				if (c == EOF) { fclose(ff); ff = nullptr; fn++; top->file_active = 0; }
				else { top->file_addr = fa++; top->file_data = c; top->file_wr = 1; }
			}
		}
		if (top->beep && !prev) beeps++;
		prev = top->beep;
		if (kn < keys.size() && clks - start >= keys[kn].at) {
			top->kb_scancode = keys[kn++].code;
			top->kb_scancode_upd ^= 1;
		}
		if (top->de) {
			if (fx < 800 && fy < 600) {
				uint32_t c = top->rgb;
				uint8_t *p = &frame[(fy * 800 + fx) * 3];
				p[0] = c >> 16; p[1] = c >> 8; p[2] = c;
			}
			fx++;
		}
		if (!top->de && prev_de) { if (frames && fx != 800) printf("bad line: %d pixels at y %d\n", fx, fy); fx = 0; fy++; }
		if (top->vs && !prev_vs) { if (frames && fy != 600) printf("bad frame: %d lines\n", fy); fy = 0; fx = 0; frames++; last = frame; }
		prev_de = top->de; prev_vs = top->vs;
	}
	uint32_t sum = 0, lit = 0;
	for (size_t i = 0; i < last.size(); i++) { sum = sum * 31 + last[i]; lit += last[i] != 0; }
	printf("%s %d ms: %d frames, beep edges %d, frame sum %08x lit %u\n", z80 ? "Z80" : "8080", ms, frames, beeps, sum, lit);
	if (ppm) {
		FILE *f = fopen(ppm, "wb");
		fprintf(f, "P6\n800 600\n255\n");
		fwrite(last.data(), 1, last.size(), f);
		fclose(f);
	}
	if (!disks[4].empty() || !disks[6].empty()) printf("disk: %d sectors read, %d written\n", disk_reads, disk_writes);
	if (save_disk) {
		FILE *f = fopen(save_disk, "wb");
		fwrite(disks[4].data(), 1, disks[4].size(), f);
		fclose(f);
	}
	int bad = 0;
	for (auto &e : expects) {
		top->dbg_addr = e.a; top->eval();
		int q = top->dbg_q;
		bool ok = e.gt ? q > e.v : q == e.v;
		printf("%06x = %02x (%s%02x) %s\n", e.a, q, e.gt ? ">" : "", e.v, ok ? "ok" : "FAIL");
		bad |= !ok;
	}
	delete top;
	return bad;
}
