{ config ? {} 
}:

let
  nixpkgs = import ../nix/nixpkgs.nix { inherit config; };

in import "${nixpkgs.path}/nixos" {
  configuration = import ./configuration.nix;
  system = "x86_64-linux";
}
