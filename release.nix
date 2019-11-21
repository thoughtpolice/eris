{ repo ? builtins.fetchGit ./.
, versionFile ? ./.version
, officialRelease ? false

, nixpkgs ? null
, config ? {}
, system ? builtins.currentSystem
}:

let
  bootstrap = import ./nix/bootstrap.nix {
    inherit nixpkgs config system;
    inherit repo officialRelease versionFile;
  };
in

let
  pkgs = bootstrap.pkgs;

  jobs = rec {
    eris = import ./. { nixpkgs = pkgs.path; inherit repo officialRelease; };
    test = import ./test.nix { nixpkgs = pkgs; };

    docker = with pkgs;
      let
        # needed for container/host resolution
        nsswitch-conf = writeTextFile {
          name = "nsswitch.conf";
          text = "hosts: dns files";
          destination = "/etc/nsswitch.conf";
        };
      in dockerTools.buildLayeredImage {
        name = "eris";
        tag = eris.version;

        contents = [ eris nsswitch-conf iana-etc cacert tzdata busybox ];

        config = {
          Entrypoint = [ "/bin/eris" ];
          Cmd = [ "--help" ];
          Env = [ "ERIS_CONFIG=/etc/eris.conf" ];
        };
      };
  };
in jobs
