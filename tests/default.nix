# SPDX-License-Identifier: MIT
{ pkgs, impurifier }:
{
  unit = impurifier.unit;
  emitter = import ./emitter.nix { inherit pkgs impurifier; };
  vm-debian = import ./debian-vm.nix { inherit pkgs impurifier; };
  vm = import ./vm.nix { inherit pkgs impurifier; };
}
