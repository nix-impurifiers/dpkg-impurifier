# SPDX-License-Identifier: MIT
{ pkgs }:
let
  manifest = builtins.fromJSON (builtins.readFile ./debian-sdk-packages.json);
  packages = map (entry: pkgs.fetchurl { inherit (entry) url name hash; }) manifest;
in
pkgs.runCommand "debian-native-frontend-packages"
  {
    __structuredAttrs = true;
    unsafeDiscardReferences.out = true;
  }
  ''
    mkdir -p $out
    ${pkgs.lib.concatMapStringsSep "\n" (package: "cp ${package} $out/${package.name}") packages}
  ''
