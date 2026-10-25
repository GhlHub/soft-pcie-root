#!/bin/sh
# Runs only in a generic ARM64 VM with no external NIC and no attached disks.
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
fail() { echo "ZCU104_SERVER_SMOKE_FAIL: $*"; sync; poweroff -f; while :; do sleep 1; done; }
mount -t proc proc /proc || fail proc
mount -t sysfs sysfs /sys || fail sysfs
mount -t devtmpfs devtmpfs /dev || fail devtmpfs
mount -t tmpfs tmpfs /run || fail run
mount -t tmpfs tmpfs /tmp || fail tmp
case "$(cat /proc/cmdline)" in *zcu104_server_smoke=1*) ;; *) fail marker ;; esac
[ ! -e /dev/vda ] && [ ! -e /dev/sda ] || fail 'unexpected disk'
for nic in /sys/class/net/*; do
 case "${nic##*/}" in
  lo) ;;
  sit0) # Linux6.6 creates an unconfigured virtual IPv6 tunnel by default.
   [ "$(readlink "$nic")" = '../../devices/virtual/net/sit0' ] || fail sit-hardware
   [ "$(cat "$nic/operstate")" = down ] || fail sit-active
   ;;
  *) fail "unexpected external NIC: $nic" ;;
 esac
done
# No matching soft-host DT node exists on virt: this checks module ABI/load
# and unload without touching any MMIO, not driver probe or NVMe operation.
modprobe zcu104-soft-pcie || fail host-module-load
[ -d /sys/module/zcu104_soft_pcie ] || fail host-module-registered
rmmod zcu104_soft_pcie || fail host-module-unload
echo ZCU104_HOST_MODULE_PASS
ip link set lo up || fail loopback
hostname zcu104-test
mkdir -p /srv/nfs /mnt/nfs3 /mnt/nfs4 /proc/fs/nfsd /var/lib/nfs /run/rpcbind /run/nfs /run/sshd
chmod 777 /srv/nfs
mount -t nfsd nfsd /proc/fs/nfsd || fail nfsd-mount
printf '/srv/nfs 127.0.0.1(rw,sync,fsid=0,no_subtree_check,root_squash,insecure)\n' > /etc/exports
rpcbind || fail rpcbind
echo 10 > /proc/fs/nfsd/nfsv4gracetime || fail nfsd-grace
/usr/lib/zcu104/services/S60nfs start || fail nfs-service
mount -t nfs -o vers=3,nolock,tcp 127.0.0.1:/srv/nfs /mnt/nfs3 || fail nfs3
printf 'loopback NFS server data integrity\n' > /mnt/nfs3/probe || fail nfs3-write
cmp /mnt/nfs3/probe /srv/nfs/probe || fail nfs3-integrity
[ "$(ls -ln /srv/nfs/probe | awk '{print $3}')" = 65534 ] || fail root-squash
umount /mnt/nfs3 || fail nfs3-umount
echo ZCU104_NFS3_PASS
sleep 12
mount -t nfs -o vers=4,tcp 127.0.0.1:/ /mnt/nfs4 || fail nfs4
cmp /mnt/nfs4/probe /srv/nfs/probe || fail nfs4-integrity
printf 'NFSv4 write\n' > /mnt/nfs4/v4 || fail nfs4-write
cmp /mnt/nfs4/v4 /srv/nfs/v4 || fail nfs4-write-integrity
umount /mnt/nfs4 || fail nfs4-umount
echo ZCU104_NFS4_PASS
# Keys exist only in this disposable VM initramfs, never the distributable image.
mkdir -p /root/.ssh
ssh-keygen -A || fail ssh-host-keys
ssh-keygen -q -t ed25519 -N '' -f /root/.ssh/id_ed25519 || fail ssh-client-key
cat /root/.ssh/id_ed25519.pub > /root/.ssh/authorized_keys
chmod 700 /root/.ssh;chmod 600 /root/.ssh/authorized_keys
sshd -t || fail sshd-config
/usr/sbin/sshd || fail sshd
ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@127.0.0.1 echo SSH_LOOPBACK_OK | grep SSH_LOOPBACK_OK || fail ssh-login
echo ZCU104_SSH_PASS
mkdir -p /run/lock /var/cache/samba /var/lock/samba /var/run/samba /etc/samba
cat > /etc/samba/smb.conf <<'CONF'
[global]
 server role = standalone server
 security = user
 map to guest = Bad User
 interfaces = lo
 bind interfaces only = yes
 smb ports = 445
[test]
 path = /srv/nfs
 guest ok = yes
 read only = no
CONF
/usr/lib/zcu104/services/S91smb start || fail smbd
sleep 1
smbclient //127.0.0.1/test -N -U guest -c 'get probe /tmp/smb-probe' || fail smb-client
cmp /tmp/smb-probe /srv/nfs/probe || fail smb-integrity
printf 'Unicode SMB filename integrity\n' > '/srv/nfs/resume-文件.txt'
smbclient //127.0.0.1/test -N -U guest -c 'get resume-文件.txt /tmp/smb-unicode' || fail smb-unicode
cmp /tmp/smb-unicode '/srv/nfs/resume-文件.txt' || fail smb-unicode-integrity
echo ZCU104_SMB_PASS
nft list ruleset || fail nft
conntrack -L || fail conntrack
mdadm --version || fail mdadm
btrfs --version || fail btrfs
nvme version || fail nvme
python3 --version || fail python
python3 -c 'import sqlite3; print(sqlite3.sqlite_version)' || fail python-sqlite
nfsdclddb --help || fail nfs-db-tool
pcie-rootctl >/tmp/pcie-usage 2>&1
[ "$?" = 2 ] || fail pcie-usage
grep 'Usage:' /tmp/pcie-usage || fail pcie-help
/usr/lib/zcu104/services/S60nfs stop || fail nfs-stop
echo ZCU104_SERVER_SMOKE_PASS
sync
poweroff -f
while :; do sleep 1; done
