# SPDX-License-Identifier: MIT
{
  pkgs,
  impurifier,
  coreSrc,
}:
let
  producer = import ./debian-frontend-producer.nix { inherit pkgs; };
in
{
  vm-bundled = import ./bundled-vm.nix { inherit pkgs impurifier; };
  vm-native = import ./native-vm.nix { inherit pkgs impurifier; };
  unit = impurifier.unit;
  frontend-sdk = producer;
  emitter = import ./emitter.nix { inherit pkgs impurifier; };
  vm-debian = import ./debian-vm.nix { inherit pkgs impurifier; };
  vm = import ./vm.nix {
    inherit pkgs impurifier;
    hardwareFixture = import (coreSrc + "/tests/hardware-fixture.nix") { inherit pkgs; };
  };
}
//
  pkgs.lib.genAttrs
    [
      "frontend-apt"
      "frontend-apt-get"
      "frontend-aptitude"
      "frontend-nala"
      "frontend-gdebi"
      "frontend-synaptic"
    ]
    (
      name:
      import ./debian-frontend-vm.nix {
        inherit pkgs impurifier producer;
        frontend = pkgs.lib.removePrefix "frontend-" name;
      }
    )
