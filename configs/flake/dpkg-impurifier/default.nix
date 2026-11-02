# SPDX-License-Identifier: MIT
{ ... }:
{ lib, inputs, ... }:
{
  flake.lib = lib.mkForce {
    dpkg-impurifier =
      { pkgs }:
      import ../../../nix {
        inherit pkgs;
        coreSrc = inputs.impurifier;
      };
  };
  perSystem =
    { pkgs, ... }:
    let
      impurifier = import ../../../nix {
        inherit pkgs;
        coreSrc = inputs.impurifier;
      };
    in
    {
      packages = {
        default = impurifier.engine;
        engine = impurifier.engine;
        runtime-deb = impurifier.runtimeDeb;
        hello-net-deb = impurifier.makeNetDeb { pkg = pkgs.hello; };
        hello-offline-deb = impurifier.makeOfflineDeb { pkg = pkgs.hello; };
      };
      formatter = pkgs.nixfmt-tree;
      checks = import ../../../tests { inherit pkgs impurifier; };
    };
}
