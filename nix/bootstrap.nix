{
  # Source code of the package.
  repo

  # The nixpkgs import specification, given by a user.. Can come in one of many
  # forms:
, nixpkgs ? null

  # The file containing version information (as well as the release name) for
  # this package. The format of the version file is exactly two lines:
  #
  #     <PACKAGE VERSION>
  #     <RELEASE NAME>
  #
  # For instance, a file with the contents:
  #
  #     1.0
  #     Golden Master
  #
  # is all that's needed to describe what the build version.
, versionFile ? ./.version

  # The JSON file containing the 'locked' set of packages to use when importing
  # nixpkgs and running a build. The lockfile specifies an unambiguous nixpkgs
  # snapshot, but is only used when the `nixpkgs` parameter is set to `null`.
  # (This allows you to maintain/manipulate/update the .json file instead of
  # the nix file, if you like.)
, lockFile ? ./nixpkgs.json

  # Whether or not this build represents an official 'release build' for your
  # users to then consume. The default 'false' implies this is an unstable
  # build from a repository. When officialRelease = false, then extra version
  # information about the build (such as the Git commit revision) will be
  # included in the version field. If true, the version information will
  # exactly match the string given in `versionFile`.
, officialRelease ? false

  # The nixpkgs configuration. This can be used to apply things like global
  # package overrides to all builds.
, config ? {}

  # The system to build on. Defaults to the current system double (e.g.
  # 'x86_64-darwin'). Setting this explicitly is only useful if you're
  # interested in doing cross compilation or remote building.
, system ? builtins.currentSystem

  # The minimum Nix version that a user must have in order to build this
  # project.
, minimumNixVersion ? "2.3"
}:

with builtins;

let
  isHttp    = x: substring 0 5 (toString x) == "http:" || substring 0 6 (toString x) == "https:";
  isChannel = x: substring 0 8 (toString x) == "channel:";

  # import logic
  pkgSource =
    # Default case: a specified package set, located in nixpkgs.json, next to this file.
    if (nixpkgs == null || nixpkgs == "channel:lockfile") then (
      if pathExists lockFile == false
      then throw "Error: you specified 'nixpkgs = null', implying you have a lock file (located in ${toString lockFile}), but it doesn't exist!"
      else
        let lockfile = fromJSON (readFile lockFile);
        in fetchTarball { inherit (lockfile) url sha256; }
    )

    # Attrs case: a package set that's specified inline
    else if isAttrs nixpkgs then (fetchTarball { inherit (nixpkgs) url sha256; })

    # Path case: the user gave an absolute path to some Nixpkgs checkout or whatnot. We can just return it.
    else if isPath nixpkgs then nixpkgs

    # HTTP/channel case: an attempted fetch from some HTTP(S) URL. Use fetchTarball without a sha256.
    else if (isHttp nixpkgs || isChannel nixpkgs) then (fetchTarball { url = nixpkgs; })

    # Otherwise, this is invalid
    else throw "Invalid nixpkgs configuration for '${toString nixpkgs}'! (try a path, http URL, or 'null')";

  overlays =
    let
      files = builtins.filter (f:
        let ext = builtins.substring (builtins.stringLength f - 4) 4 f;
        in ext == ".nix"
      ) (builtins.attrNames (builtins.readDir ./overlays));
    in builtins.map (x: import (./. + "/overlays/${x}")) files;

  pkgs = import pkgSource { inherit config system overlays; };

  versionInfo = pkgs.lib.splitString "\n" (pkgs.lib.fileContents versionFile);
  basever = builtins.elemAt versionInfo 0;
  vsuffix = pkgs.lib.optionalString (!officialRelease)
    "+${toString repo.revCount}-g${repo.shortRev}";

  relname = builtins.elemAt versionInfo 1;
  version = "${basever}${vsuffix}";
in

# Finally, check the nix version before importing the actual component we want.
if !((compareVersions nixVersion minimumNixVersion) >= 0)
  then throw ("Invalid Nix version '" + nixVersion + "'; at least " + minimumNixVersion + " is required!")
  else { inherit pkgs relname version; }
