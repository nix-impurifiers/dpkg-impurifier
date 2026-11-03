# SPDX-License-Identifier: MIT
{
  pkgs,
  impurifier,
  producer,
  frontend ? "aptitude",
}:
let
  observer = pkgs.writeShellScript "synaptic-config-observer" ''
    grep -q '^administrator$' /etc/frontend-tool.conf 2>/dev/null || exit 0
    while true; do
      if window=$(${pkgs.xdotool}/bin/xdotool search --onlyvisible --name '^synaptic$' 2>/dev/null); then
        ${pkgs.xdotool}/bin/xdotool windowfocus --sync "$window"
        ${pkgs.xdotool}/bin/xdotool key alt+k
        echo kept > /packages/kept-config
        exit 0
      fi
      for visible in $(${pkgs.xdotool}/bin/xdotool search --onlyvisible --class Synaptic 2>/dev/null); do
        ${pkgs.xdotool}/bin/xdotool getwindowname "$visible" || true
      done
      sleep 0.5
    done
  '';
  tool =
    version:
    pkgs.runCommand "frontend-tool-${version}"
      {
        pname = "frontend-tool";
        inherit version;
      }
      ''
        mkdir -p $out/bin
        printf '#!${pkgs.busybox}/bin/sh\necho ${version}\n' > $out/bin/frontend-tool
        chmod +x $out/bin/frontend-tool
      '';
  app =
    offline: version:
    impurifier.makeDeb {
      pkg = tool version;
      inherit offline;
      configFiles."/etc/frontend-tool.conf" = pkgs.writeText "frontend-tool.conf" "version=${version}\n";
    };
  provider = pkgs.runCommand "native-nix-provider.deb" { nativeBuildInputs = [ pkgs.dpkg ]; } ''
    mkdir -p root/DEBIAN root/usr/bin
    ln -s ${pkgs.nix}/bin/nix-store root/usr/bin/nix-store
    cat > root/DEBIAN/control <<'CONTROL'
    Package: fixture-native-nix
    Version: 1
    Architecture: amd64
    Maintainer: Native VM fixture
    Description: Actual preinstalled Nix FHS entry point
    Provides: nix-external-runtime
    CONTROL
    dpkg-deb --root-owner-group --build root $out
  '';
in
pkgs.testers.runNixOSTest {
  name = "dpkg-impurifier-native-${frontend}";
  globalTimeout = 600;
  requiredFeatures = {
    kvm = false;
    devnet = false;
  };
  nodes.machine = { lib, ... }: {
    virtualisation.qemu.package = lib.mkForce pkgs.qemu;
    virtualisation.qemu.forceAccel = false;
    virtualisation.memorySize = 1536;
    virtualisation.diskSize = 4096;
    virtualisation.useNixStoreImage = true;
    virtualisation.writableStore = true;
    documentation.enable = false;
    environment.systemPackages = with pkgs; [
      nix
      python3
      dpkg
      gnutar
      util-linux
      apt
      gnupg
      xdotool
    ];
    environment.etc."synaptic-observer".source = observer;
    nix.settings.substituters = lib.mkForce [ ];
  };
  testScript = ''
    import shlex
    start_all()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("mkdir -p /srv/debian; tar xzf ${producer}/rootfs/export/rootfs.tar.gz -C /srv/debian")
    machine.succeed("mkdir -p /srv/debian/nix /srv/debian/proc /srv/debian/packages/repo /srv/debian/opt/nix /srv/debian/var/lib/dpkg-impurifier /opt/nix /var/lib/dpkg-impurifier /srv/debian/etc/nix")
    machine.succeed("mount --rbind /nix /srv/debian/nix; mount -t proc proc /srv/debian/proc; mount --rbind /dev /srv/debian/dev; mount --bind /opt/nix /srv/debian/opt/nix; mount --bind /var/lib/dpkg-impurifier /srv/debian/var/lib/dpkg-impurifier; printf 'substituters =\\nbuilders =\\nbuild-users-group =\\n' > /srv/debian/etc/nix/nix.conf")
    machine.succeed("cp ${provider} /srv/debian/packages/repo/provider.deb; cp ${impurifier.runtimeDeb} /srv/debian/packages/repo/runtime.deb; cp ${app true "1"} /srv/debian/packages/repo/offline1.deb; cp ${app true "2"} /srv/debian/packages/offline2.deb")
    machine.succeed("mkdir -m700 /root/.gnupg; gpg --batch --pinentry-mode loopback --passphrase-file /dev/null --quick-generate-key 'Debian frontend VM <debian@invalid>' rsa2048 sign 0; gpg --armor --export debian@invalid > /srv/debian/packages/key.asc")
    def publish():
        machine.succeed("cd /srv/debian/packages/repo; dpkg-scanpackages . /dev/null > Packages; apt-ftparchive release . > Release; gpg --batch --yes --armor --clearsign --output InRelease Release")
    publish()
    machine.succeed("printf 'deb [signed-by=/packages/key.asc] file:///packages/repo ./\\n' > /srv/debian/etc/apt/sources.list")
    root = "${pkgs.util-linux}/bin/setsid --wait ${pkgs.coreutils}/bin/timeout --foreground -k 2s 60s ${pkgs.coreutils}/bin/chroot /srv/debian /usr/bin/env -i HOME=/root TERM=dumb XDG_DATA_DIRS=/usr/local/share:/usr/share LC_ALL=C DEBIAN_FRONTEND=noninteractive PATH=/usr/sbin:/usr/bin:/sbin:/bin "
    if "${frontend}" == "synaptic":
        machine.succeed("systemd-run --quiet --unit=debian-frontend-display --collect -p TimeoutStopSec=2s -- ${pkgs.coreutils}/bin/chroot /srv/debian /usr/bin/Xvfb :93 -noreset -screen 0 1024x768x24 -nolisten tcp -ac")
        machine.wait_until_succeeds("${pkgs.coreutils}/bin/chroot /srv/debian /usr/bin/env DISPLAY=:93 ${pkgs.xdotool}/bin/xdotool getdisplaygeometry", timeout=20)
        root += "DISPLAY=:93 "
    machine.succeed(root + "apt-get update")
    machine.succeed("sha256sum /srv/debian/var/lib/apt/lists/*InRelease > /srv/trusted-index.sha; sed -i 's/^Date:/Changed-Date:/' /srv/debian/packages/repo/InRelease")
    _status, output = machine.execute(root + "apt-get update 2>&1")
    assert "Message has been manipulated" in output or "signature verification failed" in output, output
    machine.succeed("sha256sum -c /srv/trusted-index.sha")
    publish()
    machine.succeed(root + "apt-get update")
    print(machine.succeed(root + "${frontend}" + " --help"))
    def invoke(action, package):
        if "${frontend}" == "gdebi":
            if action == "install":
                return root + "/bin/sh -c 'gdebi -n -o Dpkg::Options::=--force-confold /packages/repo/offline*.deb'"
            return root + "apt-get -y -o Dpkg::Options::=--force-confold " + action + " " + package
        if "${frontend}" == "synaptic":
            machine.succeed("printf '" + package + " " + action + "\\n' > /srv/debian/packages/selections")
            native = "${observer} >/packages/observer.log 2>&1 & watcher=$!; synaptic --non-interactive --hide-main-window -o Synaptic::closeZvt=true --set-selections-file=/packages/selections; result=$?; if [ $result -ne 0 ]; then tail -n 20 /packages/observer.log; fi; kill $watcher 2>/dev/null || true; exit $result"
            return "systemd-run --quiet --pipe --wait --collect -p RuntimeMaxSec=45s -p TimeoutStopSec=2s -- " + root + "/bin/sh -c " + shlex.quote(native)
        if "${frontend}" == "nala":
            return root + "nala " + action + " -y --no-update --raw-dpkg -o Dpkg::Options::=--force-confold " + package
        return root + "${frontend} -y -o Dpkg::Options::=--force-confold " + action + " " + package
    def operate(action, package):
        status, output = machine.execute(invoke(action, package))
        if status != 0:
            print(machine.execute("tail -n 40 /srv/debian/packages/observer.log; chroot /srv/debian /usr/bin/dpkg --audit"))
        assert status == 0, output
    operate("install", "frontend-tool-offline")
    machine.succeed("chroot --userspec=65534:65534 /srv/debian /opt/nix/profile/bin/frontend-tool | grep '^1$'")
    machine.succeed(root + "dpkg --verify frontend-tool-offline")
    machine.succeed("sha256sum /srv/debian/usr/share/nix-profile.d/frontend-tool.json > /srv/payload.sha; nix-collect-garbage -d; sha256sum -c /srv/payload.sha; test -e ${builtins.unsafeDiscardStringContext (toString (tool "1"))}")
    if "${frontend}" == "gdebi":
        machine.succeed("printf 'force-confold\\n' > /srv/debian/etc/dpkg/dpkg.cfg.d/impurifier-fixture")
    machine.succeed("echo administrator > /srv/debian/etc/frontend-tool.conf; rm /srv/debian/packages/repo/offline1.deb; cp /srv/debian/packages/offline2.deb /srv/debian/packages/repo/offline2.deb")
    publish()
    machine.succeed(root + "apt-get update")
    operate("install", "frontend-tool-offline")
    machine.succeed("chroot /srv/debian /opt/nix/profile/bin/frontend-tool | grep '^2$'; grep administrator /srv/debian/etc/frontend-tool.conf")
    if "${frontend}" == "synaptic":
        machine.succeed("grep '^kept$' /srv/debian/packages/kept-config")
    operate("purge", "frontend-tool-offline")
    machine.fail("test -x /opt/nix/profile/bin/frontend-tool")
    machine.fail("test -e /srv/debian/etc/frontend-tool.conf")
    if machine.execute(root + "dpkg --status dpkg-impurifier")[0] == 0:
        operate("purge", "dpkg-impurifier")
    machine.succeed("nix-collect-garbage -d")
    machine.fail("test -e ${builtins.unsafeDiscardStringContext (toString (tool "2"))}")
    machine.fail("test -e ${builtins.unsafeDiscardStringContext (toString (tool "1"))}")
    assert not machine.succeed(root + "dpkg --audit").strip()
    if "${frontend}" == "synaptic":
        machine.succeed("systemctl stop debian-frontend-display")
  '';
}
