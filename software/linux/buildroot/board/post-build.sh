#!/bin/sh
set -eu
target=$1
# Keep servers opt-in; DHCP client networking uses Buildroot's standard init.
mkdir -p "$target/usr/lib/zcu104/services" "$target/srv/nfs"
for service in S30rpcbind S60nfs S50sshd S91smb S80dnsmasq; do
 if [ -e "$target/etc/init.d/$service" ]; then
  mv "$target/etc/init.d/$service" "$target/usr/lib/zcu104/services/"
 fi
done
for service in S60nfs S91smb; do
 install -m 0755 "$BR2_EXTERNAL_ZCU104_PATH/board/services/$service" "$target/usr/lib/zcu104/services/$service"
done
mkdir -p "$target/var/lib/nfs/nfsdcld" "$target/var/lib/nfs/sm" "$target/var/lib/nfs/sm.bak"
cat > "$BINARIES_DIR/extlinux.conf" <<'EOF'
label zcu104-server
  kernel /Image
  devicetree /system.dtb
  append console=ttyPS0,115200 root=PARTUUID=1045a7a0-02 rw rootwait
EOF
