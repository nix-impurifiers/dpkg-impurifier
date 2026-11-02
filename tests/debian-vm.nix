# SPDX-License-Identifier: GPL-3.0-or-later
{ pkgs, impurifier }:
let
  rootfs = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/debuerreotype/docker-debian-artifacts/69faaf492e77aff83e4c7fc401017c9d25ecde24/trixie/oci/blobs/rootfs.tar.gz";
    hash = "sha256-odFWsKq1+wfYIqf0aB9tPtFokHNTHDT1ZogYwjNjPxE=";
  };
  tool =
    version:
    pkgs.runCommand "native-tool-${version}"
      {
        pname = "native-tool";
        inherit version;
      }
      ''
        mkdir -p $out/bin
        printf '#!${pkgs.busybox}/bin/sh\necho ${version}\n' > $out/bin/native-tool
        chmod +x $out/bin/native-tool
      '';
  package =
    offline: version:
    impurifier.makeDeb {
      pkg = tool version;
      inherit offline;
      configFiles."/etc/native-tool.conf" = pkgs.writeText "native-tool.conf" "version=${version}\n";
    };
  provider = pkgs.runCommand "preinstalled-nix-python.deb" { nativeBuildInputs = [ pkgs.dpkg ]; } ''
    mkdir -p root/DEBIAN
    cat > root/DEBIAN/control <<'CONTROL'
    Package: preinstalled-nix-python
    Version: 1
    Architecture: all
    Maintainer: Test <root@localhost>
    Description: Actual Nix and Python supplied by the VM
    Provides: nix-bin, python3
    CONTROL
    dpkg-deb --root-owner-group --build root $out
  '';
  consumer = pkgs.runCommand "native-consumer.deb" { nativeBuildInputs = [ pkgs.dpkg ]; } ''
    mkdir -p root/DEBIAN
    cat > root/DEBIAN/control <<'CONTROL'
    Package: native-consumer
    Version: 1
    Architecture: all
    Maintainer: Test <root@localhost>
    Description: Exercises versioned virtual package dependencies
    Depends: native-tool (>= 1)
    CONTROL
    dpkg-deb --root-owner-group --build root $out
  '';
in
pkgs.testers.runNixOSTest {
  name = "dpkg-impurifier-debian-userspace";
  requiredFeatures.kvm = false;
  requiredFeatures.devnet = false;
  nodes.machine = { lib, ... }: {
    virtualisation.memorySize = 2048;
    virtualisation.diskSize = 2048;
    virtualisation.useNixStoreImage = true;
    virtualisation.writableStore = true;
    virtualisation.qemu.package = lib.mkForce pkgs.qemu;
    virtualisation.qemu.forceAccel = false;
    environment.systemPackages = [
      pkgs.nix
      pkgs.python3
      pkgs.gnutar
    ];
    nix.settings.substituters = lib.mkForce [ ];
  };
  testScript = ''
    start_all()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("mkdir -p /srv/debian; tar xzf ${rootfs} -C /srv/debian")
    machine.succeed("grep 'VERSION_ID=\"13\"' /srv/debian/etc/os-release")
    # The userspace is Debian's official image. Bind only the supplied Nix
    # runtime and its store; apt, dpkg, their database and helpers are Debian's.
    machine.succeed("mkdir -p /srv/debian/nix /srv/debian/proc /srv/debian/packages /srv/debian/opt/nix /srv/debian/var/lib/dpkg-impurifier /opt/nix /var/lib/dpkg-impurifier")
    machine.succeed("mount --rbind /nix /srv/debian/nix; mount -t proc proc /srv/debian/proc; mount --rbind /dev /srv/debian/dev; mount --bind /opt/nix /srv/debian/opt/nix; mount --bind /var/lib/dpkg-impurifier /srv/debian/var/lib/dpkg-impurifier")
    machine.succeed("ln -s ${pkgs.python3}/bin/python3 /srv/debian/usr/bin/python3; ln -s ${pkgs.nix}/bin/nix-store /srv/debian/usr/bin/nix-store")
    machine.succeed("cp ${provider} /srv/debian/packages/provider.deb; cp ${consumer} /srv/debian/packages/consumer.deb; cp ${impurifier.runtimeDeb} /srv/debian/packages/runtime.deb; cp ${package true "1"} /srv/debian/packages/offline1.deb; cp ${package false "1"} /srv/debian/packages/net1.deb; cp ${package true "2"} /srv/debian/packages/offline2.deb")
    machine.succeed("systemctl stop dhcpcd; ip link set eth0 down")
    apt = "chroot /srv/debian /usr/bin/env PATH=/usr/sbin:/usr/bin:/sbin:/bin /usr/bin/apt-get -y -o Dpkg::Options::=--force-confold "
    with subtest("Debian apt resolves versioned Provides and installs offline"):
        machine.succeed(apt + "install /packages/provider.deb /packages/runtime.deb /packages/consumer.deb /packages/offline1.deb")
        machine.succeed("chroot /srv/debian /opt/nix/profile/bin/native-tool | grep '^1$'")
        machine.succeed("chroot /srv/debian /usr/bin/dpkg-query -W native-consumer native-tool-offline")
    with subtest("apt switches providers and preserves native conffiles"):
        machine.succeed("echo local > /srv/debian/etc/native-tool.conf")
        machine.succeed(apt + "install /packages/net1.deb")
        machine.succeed("chroot /srv/debian /opt/nix/profile/bin/native-tool | grep '^1$'")
        machine.succeed(apt + "install /packages/offline2.deb")
        machine.succeed("chroot /srv/debian /opt/nix/profile/bin/native-tool | grep '^2$'; grep local /srv/debian/etc/native-tool.conf")
    with subtest("apt removes intent; purge removes configuration"):
        machine.succeed(apt + "purge native-consumer native-tool-offline native-tool-net")
        machine.fail("test -e /srv/debian/etc/native-tool.conf")
        machine.fail("test -e /opt/nix/profile/bin/native-tool")
  '';
}
