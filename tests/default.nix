# SPDX-License-Identifier: GPL-3.0-or-later
{ pkgs, impurifier }:
{
  unit = pkgs.runCommand "impurifier-unit" { nativeBuildInputs = [ pkgs.python3 ]; } ''
    cp -r ${../.} source
    python3 source/tests/test_engine.py
    touch $out
  '';
  emitter = import ./emitter.nix { inherit pkgs impurifier; };
  vm-debian = import ./debian-vm.nix { inherit pkgs impurifier; };
  vm = import ./vm.nix { inherit pkgs impurifier; };
}
