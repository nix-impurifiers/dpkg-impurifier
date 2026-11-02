# SPDX-License-Identifier: MIT
{
  pkgs,
  impurifier,
  coreSrc,
}:
{
  unit = impurifier.unit;
  emitter = import ./emitter.nix { inherit pkgs impurifier; };
  vm-debian = import ./debian-vm.nix { inherit pkgs impurifier; };
  vm = import ./vm.nix {
    inherit pkgs impurifier;
    hardwareFixture = import (coreSrc + "/tests/hardware-fixture.nix") { inherit pkgs; };
  };
}
