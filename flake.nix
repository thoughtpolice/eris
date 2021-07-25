{
  description = "Serve your /nix/store directory over the internet";

  outputs = { self }: {
    nixosModules.eris = import ./module.nix;
  };
}
