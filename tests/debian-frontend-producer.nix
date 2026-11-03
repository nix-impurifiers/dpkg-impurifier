# SPDX-License-Identifier: MIT
{ pkgs }:
let
  rootfs = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/debuerreotype/docker-debian-artifacts/69faaf492e77aff83e4c7fc401017c9d25ecde24/trixie/oci/blobs/rootfs.tar.gz";
    hash = "sha256-odFWsKq1+wfYIqf0aB9tPtFokHNTHDT1ZogYwjNjPxE=";
  };
  sdk = import ./debian-sdk.nix { inherit pkgs; };
in
pkgs.testers.runNixOSTest {
  name = "dpkg-impurifier-debian-frontend-producer";
  globalTimeout = 900;
  requiredFeatures = {
    kvm = false;
    devnet = false;
  };
  nodes.machine = { lib, ... }: {
    virtualisation.qemu.package = lib.mkForce pkgs.qemu;
    virtualisation.qemu.forceAccel = false;
    virtualisation.memorySize = 2048;
    virtualisation.diskSize = 8192;
    documentation.enable = false;
    environment.systemPackages = [ pkgs.gnutar ];
  };
  testScript = ''
    start_all()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("mkdir -p /srv/debian; tar xzf ${rootfs} -C /srv/debian; mkdir -p /srv/debian/packages; cp -r ${sdk} /srv/debian/packages/sdk")
    machine.succeed("rm -f /srv/debian/etc/apt/sources.list /srv/debian/etc/apt/sources.list.d/*; systemctl stop dhcpcd; ip link set eth0 down")
    machine.succeed("mount --rbind /dev /srv/debian/dev; mount -t proc proc /srv/debian/proc")
    machine.succeed("chroot /srv/debian /usr/bin/env DEBIAN_FRONTEND=noninteractive PATH=/usr/sbin:/usr/bin:/sbin:/bin /bin/sh -c 'apt-get -y --no-install-recommends install /packages/sdk/*.deb'")
    machine.succeed("chroot /srv/debian /usr/bin/dpkg --audit")
    print(machine.succeed("chroot /srv/debian /usr/bin/dpkg-query -W aptitude nala gdebi-core synaptic xvfb"))
    machine.succeed("umount /srv/debian/proc; umount -R /srv/debian/dev; rm -rf /srv/debian/packages; mkdir -p /export; tar --numeric-owner -C /srv/debian -czf /export/rootfs.tar.gz .")
    machine.copy_from_machine("/export", "rootfs")
  '';
}
