# SPDX-License-Identifier: MIT
{ pkgs, impurifier }:
let
  producer = import ./debian-frontend-producer.nix { inherit pkgs; };
  rootfs = "${producer}/rootfs/export/rootfs.tar.gz";
  staticNix = import ./static-nix.nix { inherit pkgs; };
  runtime = impurifier.makeRuntimeDeb {
    bundledNixStore = "${staticNix}/bin/nix-store";
    bundledNixNotices = [ "${staticNix.src}/COPYING" ];
  };
  externalClient = pkgs.writeText "external-nix-store" ''
    #!/bin/sh
    echo external >> /tmp/client.log
    exec /usr/lib/dpkg-impurifier/nix-store "$@"
  '';
  application = impurifier.makeOfflineDeb { pkg = pkgs.hello; };
in
pkgs.testers.runNixOSTest {
  name = "dpkg-bundled-static-nix";
  requiredFeatures.kvm = false;
  requiredFeatures.devnet = false;
  nodes.machine = { lib, ... }: {
    virtualisation.memorySize = 2048;
    virtualisation.qemu.package = lib.mkForce pkgs.qemu;
    virtualisation.qemu.forceAccel = false;
    environment.systemPackages = [ pkgs.gnutar ];
  };
  testScript = ''
    start_all()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("mkdir -p /srv/target/packages; tar xzf ${rootfs} -C /srv/target")
    machine.succeed("mount --rbind /dev /srv/target/dev; mount -t proc proc /srv/target/proc")
    machine.succeed("cp ${runtime} /srv/target/packages/runtime.deb; cp ${application} /srv/target/packages/application.deb")
    with subtest("bundled static client creates a local store without a daemon"):
        machine.succeed("chroot /srv/target /usr/bin/env PATH=/usr/sbin:/usr/bin:/sbin:/bin /bin/sh -c 'apt-get -y install /packages/*.deb'")
        machine.succeed("chroot /srv/target /usr/bin/env PATH=/usr/sbin:/usr/bin:/sbin:/bin /opt/nix/profile/bin/hello | grep 'Hello, world!'")
        machine.succeed("test -f /srv/target/nix/var/nix/db/db.sqlite && test ! -e /srv/target/nix/var/nix/daemon-socket/socket")
    with subtest("compatible external client takes precedence"):
        machine.succeed("cp ${externalClient} /srv/target/usr/bin/nix-store; chmod +x /srv/target/usr/bin/nix-store")
        machine.succeed("chroot /srv/target /usr/bin/env PATH=/usr/sbin:/usr/bin:/sbin:/bin /usr/sbin/nix-profile-engine --state /var/lib/external-test --profile /opt/external-test reconcile")
        machine.succeed("grep external /srv/target/tmp/client.log")
    with subtest("removing the external client restores bundled fallback"):
        machine.succeed("rm /srv/target/usr/bin/nix-store")
        machine.succeed("chroot /srv/target /usr/bin/env PATH=/usr/sbin:/usr/bin:/sbin:/bin /usr/sbin/nix-profile-engine --state /var/lib/fallback-test --profile /opt/fallback-test reconcile")
        machine.succeed("chroot /srv/target /usr/bin/env PATH=/usr/sbin:/usr/bin:/sbin:/bin apt-get -y purge hello-offline")
        machine.fail("test -e /srv/target/opt/nix/profile/bin/hello")
  '';
}
