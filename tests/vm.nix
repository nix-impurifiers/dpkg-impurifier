# SPDX-License-Identifier: GPL-3.0-or-later
{ pkgs, impurifier }:
let
  # Tiny closure for destructive GC tests: must not appear in the VM's system closure.
  tool =
    version:
    pkgs.runCommand "projected-tool-${version}"
      {
        pname = "projected-tool";
        inherit version;
      }
      ''
        mkdir -p $out/bin
        echo '#!${pkgs.busybox}/bin/sh' > $out/bin/projected-tool
        echo 'echo ${version}' >> $out/bin/projected-tool
        chmod +x $out/bin/projected-tool
      '';
  v1 = tool "1";
  v2 = tool "2";
  config1 = pkgs.writeText "config-v1" "original\n";
  config2 = pkgs.writeText "config-v2" "updated\n";
  net1 = impurifier.makeNetDeb {
    pkg = v1;
    configFiles."/etc/projected-tool.conf" = config1;
  };
  net2 = impurifier.makeNetDeb {
    pkg = v2;
    configFiles."/etc/projected-tool.conf" = config2;
  };
  offline = impurifier.makeOfflineDeb {
    pkg = v1;
    configFiles."/etc/projected-tool.conf" = config1;
  };
  offline2 = impurifier.makeOfflineDeb { pkg = v2; };
  other = impurifier.makeNetDeb { pkg = pkgs.hello; };
  daemon =
    version:
    pkgs.runCommand "service-demo-${version}"
      {
        pname = "service-demo";
        inherit version;
      }
      ''
        mkdir -p $out/bin
        cat > $out/bin/service-demo <<'SCRIPT'
        #!${pkgs.busybox}/bin/sh
        echo ${version} > /var/lib/service-demo/version
        echo "$UNIT_REVISION" > /var/lib/service-demo/unit-revision
        exec ${pkgs.busybox}/bin/sleep infinity
        SCRIPT
        chmod +x $out/bin/service-demo
      '';
  daemonDebWith =
    version: revision:
    impurifier.makeOfflineDeb {
      pkg = daemon version;
      users.service-demo = { };
      directories."/var/lib/service-demo" = {
        owner = "service-demo:service-demo";
        mode = "0750";
      };
      systemd.unit = pkgs.writeText "service-demo.service" ''
        [Unit]
        Description=Impurifier VM fixture
        [Service]
        Type=exec
        User=service-demo
        Environment=UNIT_REVISION=${revision}
        ExecStart=/opt/nix/profile/bin/${if revision == "broken" then "missing-daemon" else "service-demo"}
        [Install]
        WantedBy=multi-user.target
      '';
    };
  daemonDeb = version: daemonDebWith version "first";
  # Model a preinstalled Nix/Python runtime in dpkg's database. The VM provides
  # the actual executables; this package installs no replacements for them.
  runtimeProvider = pkgs.runCommand "vm-runtime.deb" { nativeBuildInputs = [ pkgs.dpkg ]; } ''
    mkdir -p root/DEBIAN
    cat > root/DEBIAN/control <<'CONTROL'
    Package: vm-runtime
    Version: 1
    Architecture: all
    Maintainer: VM <root@localhost>
    Description: Existing VM runtime
    Provides: nix-bin, python3, systemd, init-system-helpers
    CONTROL
    dpkg-deb --root-owner-group --build root $out
  '';
in
pkgs.testers.runNixOSTest {
  name = "dpkg-impurifier";
  requiredFeatures.kvm = false;
  requiredFeatures.devnet = false;
  nodes.machine = { lib, ... }: {
    virtualisation.memorySize = 2048;
    virtualisation.cores = 2;
    virtualisation.qemu.package = lib.mkForce pkgs.qemu;
    virtualisation.qemu.forceAccel = false;
    virtualisation.useNixStoreImage = true;
    virtualisation.writableStore = true;
    environment.systemPackages = [
      impurifier.engine
      pkgs.dpkg
      pkgs.python3
      pkgs.nix
      pkgs.hello
    ];
    systemd.tmpfiles.rules = [
      "d /usr/bin 0755 root root -"
      "d /usr/sbin 0755 root root -"
      "L+ /usr/bin/python3 - - - - ${pkgs.python3}/bin/python3"
      "L+ /usr/bin/systemctl - - - - ${pkgs.systemd}/bin/systemctl"
      "L+ /usr/bin/systemd-sysusers - - - - ${pkgs.systemd}/bin/systemd-sysusers"
      "L+ /usr/bin/systemd-tmpfiles - - - - ${pkgs.systemd}/bin/systemd-tmpfiles"
      "L+ /usr/bin/nix-store - - - - ${pkgs.nix}/bin/nix-store"
    ];
    nix.settings = {
      substituters = lib.mkForce [ "file:///srv/impurifier-cache?trusted=1" ];
      auto-optimise-store = false;
    };
    # Store paths appear only as strings here; offline bundles carry the bytes.
    environment.etc."impurifier-fixtures.json".text = builtins.toJSON {
      v1 = builtins.unsafeDiscardStringContext (toString v1);
      v2 = builtins.unsafeDiscardStringContext (toString v2);
    };
  };
  testScript = ''
    import json
    import shlex
    start_all()
    machine.wait_for_unit("multi-user.target")
    # Expose a native-style mutable unit directory for package enable/disable.
    machine.succeed("cp -rL /etc/systemd/system /tmp/systemd-system; chmod -R u+w /tmp/systemd-system; rm /etc/systemd/system; mv /tmp/systemd-system /etc/systemd/system; systemctl daemon-reload")
    machine.succeed("mkdir -p /var/lib/dpkg/updates /var/lib/dpkg/info; touch /var/lib/dpkg/status")
    machine.succeed("dpkg -i ${runtimeProvider} ${impurifier.runtimeDeb}")
    machine.succeed("mkdir -p /tmp/packages")
    # Copy artifacts off the shared read-only store so destructive checks do not
    # accidentally keep application outputs alive through the test inputs.
    machine.succeed("cp ${net1} /tmp/packages/v1.deb; cp ${net2} /tmp/packages/v2.deb; cp ${offline} /tmp/packages/offline.deb; cp ${other} /tmp/packages/hello.deb; cp ${offline2} /tmp/packages/offline2.deb; cp ${daemonDeb "1"} /tmp/packages/daemon1.deb; cp ${daemonDeb "2"} /tmp/packages/daemon2.deb; cp ${daemonDebWith "2" "second"} /tmp/packages/daemon-unit2.deb; cp ${daemonDebWith "2" "broken"} /tmp/packages/daemon-broken.deb")
    paths = json.loads(machine.succeed("cat /etc/impurifier-fixtures.json"))
    engine = "/usr/sbin/nix-profile-engine"
    with subtest("failed substitution preserves active generation and is retryable"):
        before = machine.succeed("readlink /opt/nix/profile").strip()
        machine.fail("dpkg -i /tmp/packages/v1.deb")
        assert machine.succeed("readlink /opt/nix/profile").strip() == before
        machine.fail("test -e /opt/nix/profile/bin/projected-tool")
    with subtest("offline flavor imports closure without network"):
        machine.succeed("systemctl stop dhcpcd; ip link set eth0 down")
        machine.succeed("dpkg --unpack /tmp/packages/offline.deb; dpkg --configure --pending")
        machine.succeed("test $(/opt/nix/profile/bin/projected-tool) = 1")
        machine.succeed("dpkg-query -W -f='" + "$" + "{Status}' projected-tool-offline | grep 'install ok installed'")
    with subtest("batched descriptors, priorities and failure isolation"):
        machine.succeed("dpkg -i /tmp/packages/hello.deb")
        machine.succeed("/opt/nix/profile/bin/hello | grep Hello")
        before = machine.succeed("readlink /opt/nix/profile").strip()
        machine.succeed("cp /usr/share/nix-profile.d/projected-tool.json /tmp/original.json")
        machine.succeed("echo '{}' > /usr/share/nix-profile.d/bad.json")
        machine.fail(engine)
        assert machine.succeed("readlink /opt/nix/profile").strip() == before
        machine.succeed("rm /usr/share/nix-profile.d/bad.json")
        machine.succeed(engine + " | grep unchanged")
    with subtest("two packages in one transaction activate one generation"):
        before_count = int(machine.succeed("find /var/lib/dpkg-impurifier/generations -mindepth 1 -maxdepth 1 -type d | wc -l"))
        output = machine.succeed("dpkg -i ${
          impurifier.makeOfflineDeb {
            pkg = pkgs.hello;
            name = "batch-a";
            version = "1";
          }
        } ${
          impurifier.makeOfflineDeb {
            pkg = pkgs.hello;
            name = "batch-b";
            version = "1";
          }
        }")
        assert output.count("activated ") == 1, output
        after_count = int(machine.succeed("find /var/lib/dpkg-impurifier/generations -mindepth 1 -maxdepth 1 -type d | wc -l"))
        assert after_count == before_count + 1
        machine.succeed("dpkg -r batch-a-offline batch-b-offline")
    with subtest("rooted generations survive garbage collection"):
        machine.succeed("nix-store --gc")
        machine.succeed("test $(/opt/nix/profile/bin/projected-tool) = 1")
    with subtest("flavor switch preserves profile and conffile edits"):
        machine.succeed("echo local > /etc/projected-tool.conf")
        before = machine.succeed("readlink /opt/nix/profile").strip()
        machine.succeed("dpkg --force-confold -i /tmp/packages/v1.deb")
        machine.succeed("test $(/opt/nix/profile/bin/projected-tool) = 1; grep local /etc/projected-tool.conf")
    with subtest("net upgrade substitutes from administrator-configured cache"):
        machine.succeed("dpkg-deb -x /tmp/packages/offline2.deb /tmp/cache-source; mkdir -p /srv/impurifier-cache; cp -r /tmp/cache-source/usr/share/dpkg-impurifier/offline/projected-tool/. /srv/impurifier-cache/")
        machine.succeed("dpkg --force-confold -i /tmp/packages/v2.deb")
        machine.succeed("test $(/opt/nix/profile/bin/projected-tool) = 2; grep local /etc/projected-tool.conf")
    with subtest("collision leaves old profile active; priority resolves it"):
        collision = dict(name="collision", version="1", priority=5, installable=paths["v1"])
        def write_collision():
            machine.succeed("printf %s " + shlex.quote(json.dumps(collision)) + " > /usr/share/nix-profile.d/collision.json")
        write_collision()
        before = machine.succeed("readlink /opt/nix/profile").strip()
        machine.fail(engine)
        assert machine.succeed("readlink /opt/nix/profile").strip() == before
        collision["priority"] = 10
        write_collision()
        machine.succeed(engine)
        machine.succeed("test $(/opt/nix/profile/bin/projected-tool) = 2")
        machine.succeed("rm /usr/share/nix-profile.d/collision.json")
    with subtest("concurrent reconciliations serialize and converge"):
        machine.succeed(engine + " & " + engine + " & wait")
        machine.succeed(engine + " | grep unchanged")
    with subtest("declarative service starts after projection, provisions user and directory"):
        machine.succeed("dpkg -i /tmp/packages/daemon1.deb")
        machine.wait_for_unit("service-demo.service")
        machine.wait_until_succeeds("grep '^1$' /var/lib/service-demo/version")
        machine.succeed("id service-demo; test $(stat -c %a /var/lib/service-demo) = 750; test $(stat -c %U /var/lib/service-demo) = service-demo")
    with subtest("upgrade restarts running service on the new binary"):
        machine.succeed("dpkg -i /tmp/packages/daemon2.deb")
        machine.wait_until_succeeds("grep '^2$' /var/lib/service-demo/version")
    with subtest("unit-only upgrades restart the same binary"):
        machine.succeed("dpkg -i /tmp/packages/daemon-unit2.deb")
        machine.wait_until_succeeds("grep '^second$' /var/lib/service-demo/unit-revision")
    with subtest("failed restart remains pending and recovers on the fixed package"):
        machine.fail("dpkg -i /tmp/packages/daemon-broken.deb")
        machine.succeed("dpkg --unpack /tmp/packages/daemon2.deb; dpkg --configure --pending")
        machine.wait_for_unit("service-demo.service")
        machine.wait_until_succeeds("grep '^first$' /var/lib/service-demo/unit-revision")
    with subtest("upgrade preserves administrator stop and disable decisions"):
        machine.succeed("systemctl disable --now service-demo.service")
        machine.succeed("dpkg -i /tmp/packages/daemon1.deb")
        machine.fail("systemctl is-active --quiet service-demo.service")
        machine.fail("systemctl is-enabled --quiet service-demo.service")
    with subtest("remove stops service and retains persistent data and account"):
        machine.succeed("systemctl enable --now service-demo.service")
        machine.succeed("dpkg -r service-demo-offline")
        machine.fail("systemctl is-active --quiet service-demo.service")
        machine.fail("test -L /etc/systemd/system/multi-user.target.wants/service-demo.service")
        machine.succeed("id service-demo; test -d /var/lib/service-demo")
    with subtest("removal updates profile, retains config; purge removes config"):
        machine.succeed("dpkg -r projected-tool-net hello-net")
        machine.fail("test -e /opt/nix/profile/bin/projected-tool")
        machine.fail("test -e /opt/nix/profile/bin/hello")
        machine.succeed("grep local /etc/projected-tool.conf")
        machine.succeed("dpkg --purge projected-tool-net projected-tool-offline")
        machine.fail("test -e /etc/projected-tool.conf")
    with subtest("explicit generation pruning preserves active profile"):
        machine.succeed(engine + " prune --keep 0")
        machine.succeed("nix-store --gc; test -d /opt/nix/profile")
  '';
}
