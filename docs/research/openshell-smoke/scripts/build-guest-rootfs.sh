#!/bin/bash
# Build an Ubuntu 24.04 (noble) rootfs with generic kernel, systemd, sshd, Docker CE, proxy CA + proxy env,
# then pack it into a sparse raw ext4 disk and extract kernel/initrd for direct -kernel boot.
# Run on the outer sbx VM. Needs: debootstrap, e2fsprogs, sudo. Outputs under /tmp/openshell-smoke/guest/.
set -euo pipefail
W=/tmp/openshell-smoke/guest
ROOT=$W/rootfs
DISK=$W/disk.raw
DISK_SIZE=${DISK_SIZE:-10G}
PROXY=${PROXY:-http://gateway.docker.internal:3128}
mkdir -p $W
[ -f $W/id_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -f $W/id_ed25519
if [ ! -d $ROOT/usr ]; then
  sudo -E debootstrap --variant=minbase --include=ca-certificates,gnupg,curl,sudo \
    noble $ROOT http://archive.ubuntu.com/ubuntu
fi
sudo cp /usr/local/share/ca-certificates/proxy-ca.crt $ROOT/usr/local/share/ca-certificates/proxy-ca.crt
# apt: universe + updates, via proxy (http to archive.ubuntu.com is allowed)
sudo tee $ROOT/etc/apt/sources.list.d/ubuntu.sources >/dev/null <<S
Types: deb
URIs: http://archive.ubuntu.com/ubuntu
Suites: noble noble-updates noble-security
Components: main universe
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
S
sudo rm -f $ROOT/etc/apt/sources.list
echo "Acquire::http::Proxy \"$PROXY\";" | sudo tee $ROOT/etc/apt/apt.conf.d/90proxy >/dev/null
sudo mount -t proc proc $ROOT/proc; sudo mount --rbind /sys $ROOT/sys; sudo mount --rbind /dev $ROOT/dev
trap 'sudo umount -R $ROOT/proc $ROOT/sys $ROOT/dev 2>/dev/null || true' EXIT
sudo chroot $ROOT /bin/bash -euxc "
export DEBIAN_FRONTEND=noninteractive http_proxy=$PROXY https_proxy=$PROXY
update-ca-certificates
apt-get update
apt-get install -y --no-install-recommends linux-image-generic initramfs-tools systemd-sysv systemd-resolved udev kmod \
  openssh-server iproute2 iputils-ping netcat-openbsd e2fsprogs sqlite3 python3 jq less vim-tiny git xz-utils iptables \
  ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
echo 'deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable' > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin
"
sudo chroot $ROOT /bin/bash -euxc "
echo openshell-guest > /etc/hostname
echo '127.0.0.1 localhost openshell-guest' > /etc/hosts
id smoke 2>/dev/null || useradd -m -s /bin/bash -G sudo,docker smoke
echo 'smoke ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/smoke
passwd -d root || true
mkdir -p /home/smoke/.ssh /root/.ssh
"
sudo install -d -m 700 -o root -g root $ROOT/root/.ssh
sudo cp $W/id_ed25519.pub $ROOT/root/.ssh/authorized_keys
sudo cp $W/id_ed25519.pub $ROOT/home/smoke/.ssh/authorized_keys
sudo chroot $ROOT chown -R smoke:smoke /home/smoke/.ssh
# network: DHCP on any virtio nic via networkd; DNS from slirp (10.0.2.3)
sudo tee $ROOT/etc/systemd/network/10-all.network >/dev/null <<N
[Match]
Name=en* eth*
[Network]
DHCP=ipv4
N
sudo chroot $ROOT systemctl enable systemd-networkd systemd-resolved ssh docker containerd
sudo ln -sf ../run/systemd/resolve/stub-resolv.conf $ROOT/etc/resolv.conf
sudo tee $ROOT/etc/ssh/sshd_config.d/10-smoke.conf >/dev/null <<N
PermitRootLogin prohibit-password
N
# proxy env everywhere in the guest (the guest reaches the outside only via the sbx proxy)
sudo tee $ROOT/etc/environment >/dev/null <<N
http_proxy=$PROXY
https_proxy=$PROXY
HTTP_PROXY=$PROXY
HTTPS_PROXY=$PROXY
no_proxy=localhost,127.0.0.1,::1,10.0.2.2,172.16.0.0/12
NO_PROXY=localhost,127.0.0.1,::1,10.0.2.2,172.16.0.0/12
SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/proxy-ca.crt
N
sudo mkdir -p $ROOT/etc/systemd/system/docker.service.d
sudo tee $ROOT/etc/systemd/system/docker.service.d/proxy.conf >/dev/null <<N
[Service]
Environment="HTTP_PROXY=$PROXY" "HTTPS_PROXY=$PROXY" "NO_PROXY=localhost,127.0.0.1,::1,10.0.2.2,172.16.0.0/12"
N
sudo mkdir -p $ROOT/etc/systemd/system.conf.d
sudo tee $ROOT/etc/systemd/system.conf.d/proxy.conf >/dev/null <<N
[Manager]
DefaultEnvironment="http_proxy=$PROXY" "https_proxy=$PROXY" "HTTP_PROXY=$PROXY" "HTTPS_PROXY=$PROXY" "NO_PROXY=localhost,127.0.0.1,::1,10.0.2.2,172.16.0.0/12" "no_proxy=localhost,127.0.0.1,::1,10.0.2.2,172.16.0.0/12"
N
sudo tee $ROOT/etc/fstab >/dev/null <<N
/dev/vda / ext4 defaults 0 1
N
sudo umount -R $ROOT/proc $ROOT/sys $ROOT/dev; trap - EXIT
# kernel + initrd out
sudo cp -L $ROOT/boot/vmlinuz $W/vmlinuz; sudo cp -L $ROOT/boot/initrd.img $W/initrd.img; sudo chmod 644 $W/vmlinuz $W/initrd.img
# pack ext4 (sparse)
rm -f $DISK; truncate -s $DISK_SIZE $DISK
sudo mkfs.ext4 -q -F -L rootfs -d $ROOT $DISK
sudo chown "$(id -un)" $DISK
echo "guest disk ready: $DISK"
