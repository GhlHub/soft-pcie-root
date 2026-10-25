#!/usr/bin/env python3
"""Install the local U-Boot FMC hook; fail if upstream integration points changed."""
from pathlib import Path
import shutil
import sys

source = Path(__file__).resolve().parent
board = Path(sys.argv[1]) / 'board/xilinx/zynqmp'
path = board / 'zynqmp.c'
text = path.read_text()
old = 'int board_late_init(void)\n{\n\tint ret, multiboot;\n'
new = ('void zcu104_fmc_vadj_init(void);\n\n' + old +
       '\n\tzcu104_fmc_vadj_init();\n')
if new not in text:
    if text.count(old) != 1:
        raise SystemExit('U-Boot board_late_init integration point changed')
    path.write_text(text.replace(old, new))
path = board / 'Makefile'
text = path.read_text()
hook = '\nifndef CONFIG_SPL_BUILD\nobj-y += fmc_vadj.o fmc_vadj_uboot.o\nendif\n'
if hook not in text:
    path.write_text(text + hook)
for name in ('fmc_vadj.h', 'fmc_vadj.c', 'fmc_vadj_uboot.c'):
    shutil.copyfile(source / name, board / name)
