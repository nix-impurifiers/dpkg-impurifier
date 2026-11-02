# SPDX-License-Identifier: GPL-3.0-or-later
{ pkgs }:
let
  inherit (pkgs) lib;
  safeFile =
    prefix: path:
    lib.hasPrefix prefix path
    && builtins.match "[A-Za-z0-9/_.+-]+" path != null
    && lib.all (part: part != "." && part != "..") (lib.splitString "/" path);
  architecture =
    if pkgs.stdenv.hostPlatform.isx86_64 then
      "amd64"
    else if pkgs.stdenv.hostPlatform.isAarch64 then
      "arm64"
    else
      throw "dpkg-impurifier: unsupported target architecture";

  engine = pkgs.runCommand "nix-profile-engine-0.1.0" { nativeBuildInputs = [ pkgs.makeWrapper ]; } ''
    mkdir -p $out/bin $out/libexec
    cp ${../src/engine.py} $out/libexec/engine.py
    makeWrapper ${pkgs.python3}/bin/python3 $out/bin/nix-profile-engine \
      --add-flags $out/libexec/engine.py \
      --prefix PATH : ${
        lib.makeBinPath [
          pkgs.nix
          pkgs.coreutils
        ]
      }
  '';

  # A local, package-owned unsigned binary cache. Only the offline mode explicitly
  # trusts this directory; host cache/signature configuration is never rewritten.
  offlineCache =
    pkg:
    pkgs.runCommand "${pkg.pname or pkg.name}-offline-cache"
      {
        nativeBuildInputs = [
          pkgs.nix
          pkgs.python3
        ];
        closure = pkgs.closureInfo { rootPaths = [ pkg ]; };
      }
      ''
        mkdir -p $out/nar
        python3 ${./offline-cache.py} "$closure/registration" "$out"
      '';

  makeDeb =
    {
      pkg,
      name ? pkg.pname,
      version ? pkg.version,
      priority ? 5,
      offline ? false,
      description ? "Nix-projected ${name}",
      configFiles ? { },
      files ? { },
      users ? { },
      directories ? { },
      systemd ? null,
      hostDependencies ? [
        "systemd"
        "init-system-helpers"
      ],
    }:
    assert lib.assertMsg (
      builtins.match "[a-z0-9][a-z0-9+.-]+" name != null
    ) "invalid Debian package name";
    assert lib.assertMsg (
      builtins.match "[0-9][A-Za-z0-9.+:~_-]*" version != null
    ) "invalid Debian version";
    assert lib.assertMsg (builtins.match "[^\n\r]+" description != null) "description must be one line";
    assert lib.assertMsg (builtins.isBool offline) "offline must be a boolean";
    assert lib.assertMsg (lib.all (
      dependency: builtins.match "[A-Za-z0-9 .,+|():<>=~-]+" dependency != null
    ) hostDependencies) "invalid host dependencies";
    assert lib.assertMsg (builtins.isInt priority) "priority must be an integer";
    assert lib.assertMsg (lib.all (safeFile "/etc/") (
      builtins.attrNames configFiles
    )) "configFiles must use safe /etc paths";
    assert lib.assertMsg (lib.all (
      path:
      safeFile "/usr/" path
      && !(lib.hasPrefix "/usr/share/nix-profile.d/" path)
      && !(lib.hasPrefix "/usr/share/dpkg-impurifier/" path)
    ) (builtins.attrNames files)) "files must use safe /usr paths outside the manifest registry";
    let
      host = import ./host.nix {
        inherit
          pkgs
          name
          users
          directories
          systemd
          ;
      };
      flavor = if offline then "offline" else "net";
      packageName = "${name}-${flavor}";
      cacheDir = "/usr/share/dpkg-impurifier/offline/${name}";
      manifest = pkgs.writeText "${name}.json" (
        builtins.toJSON (
          {
            inherit name version priority;
            installable = builtins.unsafeDiscardStringContext (toString pkg);
          }
          // lib.optionalAttrs offline { offlineCache = cacheDir; }
          // lib.optionalAttrs host.enabled { host = host.manifest; }
        )
      );
      copyFiles =
        assets:
        lib.concatStringsSep "\n" (
          lib.mapAttrsToList (
            path: value:
            let
              asset =
                if builtins.isAttrs value && !(lib.isDerivation value) then
                  (
                    {
                      source,
                      mode ? "0644",
                    }:
                    {
                      inherit source mode;
                    }
                  )
                    value
                else
                  {
                    source = value;
                    mode = "0644";
                  };
            in
            assert lib.assertMsg (builtins.match "0[0-7]{3}" asset.mode != null) "invalid file mode";
            ''
              install -Dm${asset.mode} ${lib.escapeShellArg (toString asset.source)} "root${path}"
            ''
          ) assets
        );
    in
    pkgs.runCommand "${packageName}-${version}.deb"
      {
        nativeBuildInputs = [ pkgs.dpkg ];
        passthru = { inherit manifest; };
      }
      ''
        mkdir -p root/DEBIAN root/usr/share/nix-profile.d
        cp ${manifest} root/usr/share/nix-profile.d/${name}.json
        cat > root/DEBIAN/control <<'CONTROL'
        Package: ${packageName}
        Version: ${version}
        Architecture: ${architecture}
        Maintainer: dpkg Impurifier <root@localhost>
        Description: ${description}
        Depends: dpkg-impurifier (>= 0.1.0)${
          lib.optionalString (host.enabled && hostDependencies != [ ]) (
            ", " + lib.concatStringsSep ", " hostDependencies
          )
        }
        Provides: ${name} (= ${version})
        Conflicts: ${name}-${if offline then "net" else "offline"}
        Replaces: ${name}-${if offline then "net" else "offline"}
        CONTROL
        ${copyFiles (files // host.files)}
        ${copyFiles configFiles}
        ${lib.optionalString (configFiles != { }) ''
          cat > root/DEBIAN/conffiles <<'CONFFILES'
          ${lib.concatStringsSep "\n" (builtins.attrNames configFiles)}
          CONFFILES
        ''}
        ${lib.optionalString offline ''
          mkdir -p root${cacheDir}
          cp -r ${offlineCache pkg}/. root${cacheDir}/
        ''}
        echo "Installed-Size: $(du --apparent-size -sk root | cut -f1)" >> root/DEBIAN/control
        dpkg-deb --root-owner-group --build root "$out"
      '';

  # Dependency expressions belong to the consumer's repository policy, not to
  # distro detection in the compiler. Native packages retain solver semantics.
  makeRuntimeDeb =
    {
      nixDependency ? "nix-bin | nix-external-runtime",
    }:
    assert lib.assertMsg (
      builtins.match "[A-Za-z0-9 .,+|():<>=~-]+" nixDependency != null
    ) "invalid native Nix dependency expression";
    pkgs.runCommand "dpkg-impurifier-0.1.0.deb" { nativeBuildInputs = [ pkgs.dpkg ]; } ''
      mkdir -p root/DEBIAN root/usr/lib/dpkg-impurifier root/usr/sbin
      cp ${../src/engine.py} root/usr/lib/dpkg-impurifier/engine.py
      cat > root/usr/sbin/nix-profile-engine <<'SCRIPT'
      #!/bin/sh
      export PATH=/usr/sbin:/usr/bin:/sbin:/bin:/nix/var/nix/profiles/default/bin
      exec /usr/bin/python3 /usr/lib/dpkg-impurifier/engine.py "$@"
      SCRIPT
      chmod 755 root/usr/sbin/nix-profile-engine
      cat > root/DEBIAN/control <<'CONTROL'
      Package: dpkg-impurifier
      Version: 0.1.0
      Architecture: all
      Maintainer: dpkg Impurifier <root@localhost>
      Description: Native package intent projected into a Nix profile
      Depends: python3, ${nixDependency}
      CONTROL
      echo 'interest /usr/share/nix-profile.d' > root/DEBIAN/triggers
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
  inherit
    engine
    makeDeb
    makeRuntimeDeb
    offlineCache
    ;
  runtimeDeb = makeRuntimeDeb { };
  makePackage = args: {
    net = makeDeb (args // { offline = false; });
    offline = makeDeb (args // { offline = true; });
  };
  makeNetDeb = args: makeDeb (args // { offline = false; });
  makeOfflineDeb = args: makeDeb (args // { offline = true; });
}
