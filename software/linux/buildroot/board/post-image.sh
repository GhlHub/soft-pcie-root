#!/bin/sh
set -eu
ln -fs zynqmp-zcu104-revC.dtb "$BINARIES_DIR/system.dtb"
support/scripts/genimage.sh -c "$BR2_EXTERNAL_ZCU104_PATH/board/genimage.cfg"
