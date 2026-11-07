#!/usr/bin/env python3
"""A system disk of the Orion-PRO, 800 KB: 80 tracks, 2 sides, 5 sectors of 1024 bytes.

 mkodi.py IMAGE SYSTEM [FILE...]. SYSTEM is the DOS with its boot sector at 0 (dosfdd-pro.bin of
 AltairDOS, https://github.com/serge-404/AltairDOS). Byte 2F of the boot sector tells the BIOS where
 to load it (0, 1: that page, the mode Orion-128; 2-4 the mode PRO; FF: run the sector; AltairDOS has text there and runs in page 1), the disk parameters are in the
 sector: 2 KB blocks, 128 directory entries, 4 reserved tracks. FILEs go to user 0.
"""
import os, sys
SIZE = 800 * 1024
img = bytearray(b'\xE5' * SIZE)
s = open(sys.argv[2], 'rb').read()
assert s[0] == 0xC3 and len(s) <= 20480
s = bytearray(s)
s[0x2F] = 1
img[:len(s)] = s
DIR, BLOCK = 20480, 2048
block, ent = 2, 0
for path in sys.argv[3:]:
    data = open(path, 'rb').read()
    name, ext = os.path.splitext(os.path.basename(path).upper())
    ext = ext[1:]
    nrec = (len(data) + 127) // 128
    nblk = (len(data) + BLOCK - 1) // BLOCK
    img[DIR + block * BLOCK:DIR + block * BLOCK + len(data)] = data
    ex = 0
    done = 0
    while True:
        al = [block + done + i for i in range(min(8, nblk - done))]
        e = bytearray(32)
        e[0] = 0
        e[1:9] = name.ljust(8).encode()
        e[9:12] = ext.ljust(3).encode()
        e[12] = ex
        left = nrec - ex * 128
        e[15] = min(left, 128)
        for i, x in enumerate(al):
            e[16 + 2 * i] = x & 255
            e[17 + 2 * i] = x >> 8
        img[DIR + ent * 32:DIR + ent * 32 + 32] = e
        ent += 1
        done += len(al)
        ex += 1
        if done >= nblk:
            break
    block += nblk
open(sys.argv[1], 'wb').write(img)
print(ent, 'entries, blocks up to', block)
