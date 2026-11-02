# SPDX-License-Identifier: GPL-3.0-or-later
{ pkgs, impurifier }:
{
  unit = impurifier.unit;
  emitter = import ./emitter.nix { inherit pkgs impurifier; };
  vm-debian = import ./debian-vm.nix { inherit pkgs impurifier; };
  vm = import ./vm.nix { inherit pkgs impurifier; };
}
