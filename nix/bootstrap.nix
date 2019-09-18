{ config ? {}
, system ? builtins.currentSystem
, nixpkgs ? null
, minimumNixVersion ? "2.2"
}:

with builtins;

let
  # hack: no builtins.{isPath,isHttp} :(
  isPath    = x: substring 0 1 (toString x) == "/";
  isHttp    = x: substring 0 5 (toString x) == "http:" || substring 0 6 (toString x) == "https:";
  isChannel = x: substring 0 8 (toString x) == "channel:";

  # locked package set, used by default
  lockfile = with builtins; fromJSON (readFile ./nixpkgs.json);

  # import logic
  pkgs =
    if nixpkgs == null then (fetchTarball { inherit (lockfile) url sha256; })
    else if isPath nixpkgs then nixpkgs
    else if isHttp nixpkgs then (fetchTarball { url = nixpkgs; })
    else if isChannel nixpkgs then (fetchTarball {
      url = "https://nixos.org/channels/" + (substring 8 (stringLength nixpkgs) nixpkgs) + "/nixexprs.tar.xz";
    })
    else throw "Invalid nixpkgs configuration for '${toString nixpkgs}'! (try a path, http URL, or 'null')";
in

if (compareVersions nixVersion minimumNixVersion) >= 0
  then import pkgs { inherit config system; }
  else throw ("Invalid Nix version '" + nixVersion + "'; at least " + minimumNixVersion + " is required!")
