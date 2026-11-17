#!/bin/bash
# Boot the nested Ubuntu 24.04 guest under QEMU TCG (no KVM here). ssh: ssh -p 2222 (see guest-ssh.sh)
set -euo pipefail
W=/tmp/openshell-smoke/guest
[ -f $W/qemu.pid ] && kill -0 "$(cat $W/qemu.pid)" 2>/dev/null && { echo already running; exit 0; }
nohup qemu-system-x86_64 -name openshell-guest -machine q35 -accel tcg,thread=multi -cpu max \
  -smp ${VCPUS:-12} -m ${MEM:-10240} \
  -kernel $W/vmlinuz -initrd $W/initrd.img \
  -append "root=/dev/vda rw console=ttyS0 net.ifnames=0 panic=-1" \
  -drive file=$W/disk.raw,if=virtio,format=raw,cache=unsafe \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22,hostfwd=tcp:127.0.0.1:17670-:17670 \
  -device virtio-net-pci,netdev=n0 \
  -object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-pci,rng=rng0 \
  -display none -serial file:$W/console.log -monitor none -pidfile $W/qemu.pid \
  > $W/qemu.out 2>&1 &
echo started
