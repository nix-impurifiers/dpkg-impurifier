# SPDX-License-Identifier: MIT
{ pkgs, coreSrc }:
let
  inherit (pkgs) lib;
  core = import (coreSrc + "/nix") {
    inherit pkgs;
    namespace = "dpkg-impurifier";
    sourceInfo = coreSrc;
  };
  architecture =
    if pkgs.stdenv.hostPlatform.isx86_64 then
      "amd64"
    else if pkgs.stdenv.hostPlatform.isAarch64 then
      "arm64"
    else
      throw "dpkg-impurifier: unsupported target architecture";
  makeDeb =
    args@{
      pkg,
      hostDependencies ? [
        "systemd"
        "init-system-helpers"
      ],
      ...
    }:
    let
      payload = core.makePayload (builtins.removeAttrs args [ "hostDependencies" ]);
    in
    assert lib.assertMsg (
      builtins.match "[0-9][A-Za-z0-9.+:~_-]*" payload.version != null
    ) "invalid Debian version";
    assert lib.assertMsg (lib.all (
      dependency: builtins.match "[A-Za-z0-9 .,+|():<>=~-]+" dependency != null
    ) hostDependencies) "invalid host dependencies";
    pkgs.runCommand "${payload.packageName}-${payload.version}.deb"
      {
        nativeBuildInputs = [ pkgs.dpkg ];
        passthru.manifest = payload.manifest;
      }
      ''
        mkdir -p root/DEBIAN
        cp -r ${payload}/. root/
        chmod -R u+w root
        cat > root/DEBIAN/control <<'CONTROL'
        Package: ${payload.packageName}
        Version: ${payload.version}
        Architecture: ${architecture}
        Maintainer: dpkg Impurifier <root@localhost>
        Description: ${payload.description}
        Depends: dpkg-impurifier (>= ${core.runtimeVersion})${
          lib.optionalString ((payload.hostEnabled || (args.hostDependencies or null) != null) && hostDependencies != [ ]) (
            ", " + lib.concatStringsSep ", " hostDependencies
          )
        }
        Provides: ${payload.name} (= ${payload.version})
        Conflicts: ${payload.name}-${if payload.offline then "net" else "offline"}
        Replaces: ${payload.name}-${if payload.offline then "net" else "offline"}
        CONTROL
        ${lib.optionalString (payload.configPaths != [ ]) ''
          cat > root/DEBIAN/conffiles <<'CONFFILES'
          ${lib.concatStringsSep "\n" payload.configPaths}
          CONFFILES
        ''}
        echo "Installed-Size: $(du --apparent-size -sk root | cut -f1)" >> root/DEBIAN/control
        dpkg-deb --root-owner-group --build root "$out"
      '';
  makeRuntimeDeb =
    {
      nixDependency ? "nix-bin | nix-external-runtime",
    }:
    assert lib.assertMsg (
      builtins.match "[A-Za-z0-9 .,+|():<>=~-]+" nixDependency != null
    ) "invalid native Nix dependency expression";
    pkgs.runCommand "dpkg-impurifier-${core.runtimeVersion}.deb" { nativeBuildInputs = [ pkgs.dpkg ]; }
      ''
        mkdir -p root/DEBIAN
        cp -r ${core.makeRuntimeTree { }}/. root/
        chmod -R u+w root
        cat > root/DEBIAN/control <<'CONTROL'
        Package: dpkg-impurifier
        Version: ${core.runtimeVersion}
        Architecture: all
        Maintainer: dpkg Impurifier <root@localhost>
        Description: Native package intent projected into a Nix profile
        Depends: python3, ${nixDependency}
        CONTROL
        cat > root/DEBIAN/triggers <<'TRIGGERS'
        interest /usr/share/nix-profile.d
        interest /usr/lib
        interest /usr/lib64
        interest /lib
        interest /lib64
        TRIGGERS
        cat > root/DEBIAN/postinst <<'SCRIPT'
        #!/bin/sh
        set -eu
        case "$1" in
          configure|triggered) /usr/sbin/nix-profile-engine reconcile ;;
        esac
        SCRIPT
        chmod 755 root/DEBIAN/postinst
        echo "Installed-Size: $(du --apparent-size -sk root | cut -f1)" >> root/DEBIAN/control
        dpkg-deb --root-owner-group --build root "$out"
      '';
in
{
  inherit (core)
    engine
    offlineCache
    unit
    runtimeVersion
    ;
  inherit makeDeb makeRuntimeDeb;
  runtimeDeb = makeRuntimeDeb { };
  makePackage = args: {
    net = makeDeb (args // { offline = false; });
    offline = makeDeb (args // { offline = true; });
  };
  makeNetDeb = args: makeDeb (args // { offline = false; });
  makeOfflineDeb = args: makeDeb (args // { offline = true; });
}
