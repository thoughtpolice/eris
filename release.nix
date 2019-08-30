{ repo ? builtins.fetchGit ./.
, officialRelease ? false
, config ? {}
}:

let
  pkgs = import ./nix/nixpkgs.nix { inherit config; };

  jobs = rec {
    eris = import ./. { nixpkgs = pkgs.path; eris = repo; inherit officialRelease; };
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
