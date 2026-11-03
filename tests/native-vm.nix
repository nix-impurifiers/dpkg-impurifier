# SPDX-License-Identifier: MIT
{ pkgs, impurifier }:
let
  rootfs = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/debuerreotype/docker-debian-artifacts/69faaf492e77aff83e4c7fc401017c9d25ecde24/trixie/oci/blobs/rootfs.tar.gz";
    hash = "sha256-odFWsKq1+wfYIqf0aB9tPtFokHNTHDT1ZogYwjNjPxE=";
  };
  tool =
    name: version:
    pkgs.runCommand "${name}-${version}"
      {
        pname = name;
        inherit version;
      }
      ''
        mkdir -p $out/bin
        printf '#!${pkgs.busybox}/bin/sh\necho ${name}-${version}\n' > $out/bin/${name}
        chmod +x $out/bin/${name}
      '';
  first = impurifier.makeNativeDebs { pkg = tool "native-first" "1"; };
  second = impurifier.makeNativeDebs { pkg = tool "native-second" "1"; };
  upgraded = impurifier.makeNativeDebs { pkg = tool "native-first" "2"; };
  repository = impurifier.makeNativeRepository {
    collections = [
      first
      second
    ];
  };
  updatedRepository = impurifier.makeNativeRepository {
    collections = [
      upgraded
      second
    ];
  };
in
pkgs.testers.runNixOSTest {
  name = "dpkg-native-owned-nixless";
  requiredFeatures.kvm = false;
  requiredFeatures.devnet = false;
  nodes.machine = { lib, ... }: {
    virtualisation.memorySize = 1536;
    virtualisation.qemu.package = lib.mkForce pkgs.qemu;
    virtualisation.qemu.forceAccel = false;
    environment.systemPackages = [ pkgs.gnutar ];
  };
  testScript = ''
    start_all()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("mkdir -p /srv/target/packages; tar xzf ${rootfs} -C /srv/target")
    machine.succeed("cp ${repository}/* /srv/target/packages/; rm -f /srv/target/etc/apt/sources.list /srv/target/etc/apt/sources.list.d/*; echo 'deb [trusted=yes] file:/packages ./' > /srv/target/etc/apt/sources.list")
    apt = "chroot /srv/target /usr/bin/env PATH=/usr/sbin:/usr/bin:/sbin:/bin /usr/bin/apt-get -y "
    with subtest("native install without a target Nix runtime or database"):
        machine.succeed(apt + "update")
        machine.succeed(apt + "install native-first native-second")
        machine.succeed("chroot /srv/target /usr/bin/env PATH=/usr/sbin:/usr/bin:/sbin:/bin /usr/bin/native-first | grep native-first-1")
        machine.succeed("chroot /srv/target /usr/bin/env PATH=/usr/sbin:/usr/bin:/sbin:/bin /usr/bin/native-second | grep native-second-1")
        machine.succeed("chroot /srv/target /usr/bin/env PATH=/usr/sbin:/usr/bin:/sbin:/bin /bin/sh -c 'if command -v nix || command -v nix-store; then exit 1; fi; test ! -e /nix/var/nix/db/db.sqlite && test ! -e /nix/var/nix/daemon-socket/socket'")
        machine.succeed("chroot /srv/target /usr/bin/env PATH=/usr/sbin:/usr/bin:/sbin:/bin dpkg -V")
    with subtest("native checksum metadata detects changed payload bytes"):
        executable = machine.succeed("readlink /srv/target/usr/bin/native-second").strip()
        machine.succeed(f"printf x >> /srv/target{executable}")
        machine.succeed("chroot /srv/target /usr/bin/env PATH=/usr/sbin:/usr/bin:/sbin:/bin dpkg -V | grep native-second")
        machine.succeed(f"truncate -s -1 /srv/target{executable}")
        machine.succeed("chroot /srv/target /usr/bin/env PATH=/usr/sbin:/usr/bin:/sbin:/bin dpkg -V")
    with subtest("upgrade, native dependency cleanup, and shared closure survival"):
        machine.succeed("rm /srv/target/packages/*; cp ${updatedRepository}/* /srv/target/packages/")
        machine.succeed(apt + "update")
        machine.succeed(apt + "install native-first")
        machine.succeed("chroot /srv/target /usr/bin/env PATH=/usr/sbin:/usr/bin:/sbin:/bin /usr/bin/native-first | grep native-first-2")
        machine.succeed(apt + "remove native-first")
        machine.succeed(apt + "autoremove")
        machine.succeed("chroot /srv/target /usr/bin/env PATH=/usr/sbin:/usr/bin:/sbin:/bin /usr/bin/native-second | grep native-second-1")
        machine.succeed("chroot /srv/target /usr/bin/env PATH=/usr/sbin:/usr/bin:/sbin:/bin dpkg -V")
    with subtest("native removal releases every packaged store object"):
        machine.succeed(apt + "purge native-second")
        machine.succeed(apt + "autoremove --purge")
        machine.succeed("test ! -d /srv/target/nix/store || test -z \"$(find /srv/target/nix/store -mindepth 1 -maxdepth 1 -print -quit)\"")
  '';
}
