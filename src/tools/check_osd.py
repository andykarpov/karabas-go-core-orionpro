#!/usr/bin/env python3
"""Checks the osd of a core*.json before make_core packs it: the F and FL items need different
slot numbers. The firmware keeps both kinds in one array of file slots (file_slots[slot]): two
items with one slot share the extensions, the dir and the file name of the last one (Cart A
showed only .dsk files when it was FL 0 next to the disk F 0).

usage: check_osd.py core.json (kgo2: every board of "boards")
"""
import json
import sys

d = json.load(open(sys.argv[1]))
osd = d['osd']
err = 0
# kgo2: an item with "boards" is on these boards only; each board is checked on its own
for board in d.get('boards', {'': None}):
    seen = {}
    for i, item in enumerate(osd):
        if item['type'] not in ('F', 'FL') or (board and board not in item.get('boards', [board])):
            continue
        s = item['slot']
        if s in seen:
            print('%s: %sitem %d "%s" has slot %d of item %d "%s"' % (sys.argv[1], board + ': ' if board else '',
                  i, item['name'], s, seen[s][0], seen[s][1]))
            err += 1
        seen[s] = (i, item['name'])
sys.exit(1 if err else 0)
