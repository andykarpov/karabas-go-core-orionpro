#!/usr/bin/env python3
"""A test ROM1 for sim_boot: EGA planes in four columns, then an IDE read and a write with read back.

 mkrom_pro.py ROM IMAGE. The screen: 4 bits (F8 = 14), screen with its base at 8000: column 0 R,
 1 G, 2 B, 3 I. The disk: sector LBA 0 is read to 4000; a pattern is written to LBA 2 and read to 5000.
"""
import sys
c = bytearray()
def b(*x): c.extend(x)
def out(p, v): b(0x3E, v, 0xD3, p)                 # LD A,v / OUT (p),A
def fill(addr):                                    # 256 bytes of FF at addr
    b(0x21, addr & 255, addr >> 8, 0x06, 0, 0x36, 0xFF, 0x23, 0x10, 0xFB)  # LD HL / LD B,0 / LD (HL),FF / INC HL / DJNZ
def wait(mask, val):                               # IN A,(5F) / AND mask / CP val / JR NZ
    b(0xDB, 0x5F, 0xE6, mask, 0xFE, val, 0x20, 0xF8)
def lba(n):
    out(0x5A, 1); out(0x5B, n); out(0x5C, 0); out(0x5D, 0); out(0x5E, 0xE0)
def read(addr):
    b(0x21, addr & 255, addr >> 8, 0x06, 0)        # LD HL,addr / LD B,0
    b(0xDB, 0x58, 0x77, 0x23, 0xDB, 0x57, 0x77, 0x23, 0x10, 0xF6)  # IN 58 / LD (HL),A / INC HL / IN 57 / ... / DJNZ

b(0x31, 0x00, 0xF0)                                # LD SP,F000
fill(0x8000); fill(0xC100)
out(0x08, 1); fill(0x8200); fill(0xC300); out(0x08, 0)
out(0xF8, 0x14)
wait(0xC0, 0x40)
lba(0); out(0x5F, 0x20); wait(0x88, 0x08); read(0x4000); wait(0x80, 0x00)
lba(2); out(0x5F, 0x30); wait(0x88, 0x08)
b(0x06, 0)                                         # LD B,0
b(0x78, 0x2F, 0xD3, 0x57, 0x78, 0xD3, 0x58, 0x10, 0xF7)  # LD A,B / CPL / OUT 57 / LD A,B / OUT 58 / DJNZ
wait(0x80, 0x00)
lba(2); out(0x5F, 0x20); wait(0x88, 0x08); read(0x5000); wait(0x80, 0x00)
b(0x18, 0xFE)                                      # JR $
open(sys.argv[1], 'wb').write(bytes(c).ljust(8192, b'\xFF'))
img = bytearray(1 << 20)
for i in range(256):
    img[2 * i] = i
    img[2 * i + 1] = i ^ 0xFF
open(sys.argv[2], 'wb').write(img)
