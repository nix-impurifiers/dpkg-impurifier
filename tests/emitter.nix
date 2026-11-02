# SPDX-License-Identifier: GPL-3.0-or-later
{ pkgs, impurifier }:
let
  net = impurifier.makeNetDeb { pkg = pkgs.hello; };
  closure = pkgs.closureInfo { rootPaths = [ net ]; };
  customRuntime = impurifier.makeRuntimeDeb {
    nixDependency = "our-nix-runtime (>= 2.24) | nix-bin";
  };
  invalid =
    args: !(builtins.tryEval ((impurifier.makeDeb ({ pkg = pkgs.hello; } // args)).drvPath)).success;
in
assert invalid { name = "../bad"; };
assert invalid { version = "bad"; };
assert invalid { priority = "5"; };
assert invalid { description = "bad\nDepends: injected"; };
assert invalid { configFiles."/etc/../tmp/bad" = ./default.nix; };
assert invalid { files."/usr/.." = ./default.nix; };
assert invalid { files."/usr/share/nix-profile.d/bad.json" = ./default.nix; };
assert invalid {
  configFiles."/etc/test" = {
    source = ./default.nix;
    mode = "0999";
  };
};
assert invalid { users.bad.home = "/var/lib/../tmp"; };
pkgs.runCommand "dpkg-impurifier-emitter-contract" { nativeBuildInputs = [ pkgs.dpkg ]; } ''
  test "$(dpkg-deb --field ${customRuntime} Depends)" = 'python3, our-nix-runtime (>= 2.24) | nix-bin'
  test "$(dpkg-deb --field ${net} Provides)" = 'hello (= ${pkgs.hello.version})'
  test "$(dpkg-deb --field ${net} Conflicts)" = 'hello-offline'
  if grep -Fx '${pkgs.hello}' ${closure}/store-paths; then
    echo 'net artifact must not retain the application closure' >&2
    exit 1
  fi
  dpkg-deb --extract ${net} unpacked
  test -f unpacked/usr/share/nix-profile.d/hello.json
  test ! -d unpacked/nix
  touch $out
''
