{ eris ? builtins.fetchGit ./.
, officialRelease ? false
, config ? {}
}:

let
  nixpkgs = import ./nix/nixpkgs.nix { inherit config; };

  pkg = import ./. { nixpkgs = nixpkgs.path; inherit eris officialRelease; };

  jobs = rec {
    eris = pkg;
    test = import ./test.nix { inherit nixpkgs; };

    docker = nixpkgs.dockerTools.buildLayeredImage {
      name = "eris";
      tag = "latest";

      contents = [ eris ];
      config = {
        Entrypoint = [ "/bin/eris" ];
        Cmd        = [ "--help" ];
      };
    };
  };
in jobs
