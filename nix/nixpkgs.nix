let
  # Grab the versions we specified in the JSON file
  nixpkgs   = builtins.fromJSON (builtins.readFile ./nixpkgs.json);
  # Bootstrap a copy of nixpkgs, based on this.
  src = builtins.fetchTarball { inherit (nixpkgs) url sha256; };
# Import nixpkgs, returning a lambda taking e.g. currrentSystem, config, etc
in import src
