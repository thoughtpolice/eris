{ nixpkgs }:

with builtins;

let
  system    = "x86_64-linux";
  nixosPath = nixpkgs.path + "/nixos";
  makeTest  = import (nixosPath + "/tests/make-test.nix");

  toTest = file: _: {
    name  = replaceStrings [ ".nix" ] [ "" ] file;
    value = makeTest (import (./. + "/t/${file}")) {};
  };

  tests = nixpkgs.lib.mapAttrs' toTest (builtins.readDir ./t);
in tests
