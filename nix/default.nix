# SPDX-License-Identifier: MIT
{
  pkgs,
  coreSrc,
  sourceInfo ? { },
}:
let
  inherit (pkgs) lib;
  core = import (coreSrc + "/nix") {
    inherit pkgs;
    namespace = "dpkg-impurifier";
    sourceInfo = {
      # Native updates must include adapter-only releases, not just engine pins.
      lastModified = pkgs.lib.max (if builtins.isAttrs coreSrc then coreSrc.lastModified or 0 else 0) (
        if builtins.isAttrs sourceInfo then sourceInfo.lastModified or 0 else 0
      );
    };
  };
  architecture =
    if pkgs.stdenv.hostPlatform.isx86_64 then
      "amd64"
    else if pkgs.stdenv.hostPlatform.isAarch64 then
      "arm64"
    else
      throw "dpkg-impurifier: unsupported target architecture";
  # Returns a collection: install the application and its store-object DEBs
  # together, or publish them in an ordinary APT repository.
  makeNativeDebs =
    {
      pkg,
      name ? pkg.pname,
      version ? pkg.version,
      programs ? [ (pkg.meta.mainProgram or (pkg.pname)) ],
    }:
    assert lib.assertMsg (
      builtins.match "[a-z0-9][a-z0-9+.-]+" name != null
    ) "invalid Debian package name";
    assert lib.assertMsg (
      builtins.match "[0-9][A-Za-z0-9.+:~_-]*" version != null
    ) "invalid Debian version";
    assert lib.assertMsg (
      programs != [ ]
      && lib.all (p: builtins.match "[A-Za-z0-9_+.-]+" p != null && p != "." && p != "..") programs
    ) "invalid command names";
    let
      closure = pkgs.closureInfo { rootPaths = [ pkg ]; };
      spec = pkgs.writeText "native-debs.json" (
        builtins.toJSON {
          inherit
            name
            version
            programs
            architecture
            ;
          installable = toString pkg;
        }
      );
    in
    pkgs.runCommand "${name}-${version}-native-debs"
      {
        nativeBuildInputs = [
          pkgs.python3
          pkgs.dpkg
        ];
      }
      ''
        python3 ${./native-debs.py} ${closure}/registration ${spec} "$out"
      '';
  makeNativeRepository =
    { collections }:
    pkgs.runCommand "native-closure-deb-repository"
      {
        nativeBuildInputs = [ pkgs.dpkg ];
      }
      ''
        mkdir -p "$out"
        for collection in ${lib.escapeShellArgs (map toString collections)}; do
          for package in "$collection"/*.deb; do
            destination="$out/$(basename "$package")"
            if test -e "$destination"; then
              cmp "$package" "$destination"
            else
              cp "$package" "$destination"
            fi
          done
        done
        cd "$out"
        dpkg-scanpackages . /dev/null > Packages
      '';
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
          lib.optionalString (
            (payload.hostEnabled || (args.hostDependencies or null) != null) && hostDependencies != [ ]
          ) (", " + lib.concatStringsSep ", " hostDependencies)
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
      bundledNixStore ? null,
      bundledNixNotices ? [ ],
      nixDependency ? (if bundledNixStore == null then "nix-bin | nix-external-runtime" else null),
    }:
    assert lib.assertMsg (
      (nixDependency == null && bundledNixStore != null)
      || (nixDependency != null && builtins.match "[A-Za-z0-9 .,+|():<>=~-]+" nixDependency != null)
    ) "invalid native Nix dependency expression";
    pkgs.runCommand "dpkg-impurifier-${core.runtimeVersion}.deb" { nativeBuildInputs = [ pkgs.dpkg ]; }
      ''
        mkdir -p root/DEBIAN
        cp -r ${core.makeRuntimeTree { inherit bundledNixStore bundledNixNotices; }}/. root/
        chmod -R u+w root
        cat > root/DEBIAN/control <<'CONTROL'
        Package: dpkg-impurifier
        Version: ${core.runtimeVersion}
        Architecture: ${if bundledNixStore == null then "all" else architecture}
        Maintainer: dpkg Impurifier <root@localhost>
        Description: Native package intent projected into a Nix profile
        Depends: python3${lib.optionalString (nixDependency != null) (", " + nixDependency)}
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
        cat > root/DEBIAN/prerm <<'SCRIPT'
        #!/bin/sh
        set -eu
        # A solver may remove the runtime with its final dependent application.
        # Reconcile and release retained generations before this engine vanishes.
        if [ "$1" = remove ]; then
          /usr/sbin/nix-profile-engine reconcile
          /usr/sbin/nix-profile-engine prune --keep 0
        fi
        SCRIPT
        chmod 755 root/DEBIAN/postinst root/DEBIAN/prerm
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
  inherit
    makeDeb
    makeRuntimeDeb
    makeNativeDebs
    makeNativeRepository
    ;
  runtimeDeb = makeRuntimeDeb { };
  makePackage = args: {
    net = makeDeb (args // { offline = false; });
    offline = makeDeb (args // { offline = true; });
  };
  makeNetDeb = args: makeDeb (args // { offline = false; });
  makeOfflineDeb = args: makeDeb (args // { offline = true; });
}
