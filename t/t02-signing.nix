{ pkgs, ... }:

let
  testPkg = pkgs.postgresql;

  configFile = pkgs.writeText "eris.conf" ''
    {
      listen => ['http://[::]:80'],
      signing => {
        host    => 'eris-1',
        private => '${./cache.sk}',
      },
    }
  '';

  copyScript = pkgs.writeShellScriptBin "copy-test" ''
    set -e

    PUBKEY=$(curl -f -s http://eris/v1/public-key)
    nix copy \
      --option trusted-public-keys "$PUBKEY" \
      --from http://eris \
      --to /root/test-store \
      "$@"
  '';
in
{
  nodes = {
    eris = { config, pkgs, ... }:
      { imports = [ ../module.nix ];

        services.eris-git = {
          enable = true;
          configFile = "${configFile}";
        };

        networking.firewall.allowedTCPPorts = [ 80 ];
        environment.systemPackages = [ testPkg ];
      };

    client01 = { config, pkgs, ... }:
      { imports = [];

        nix.binaryCaches = [ "http://eris" ];
        environment.systemPackages = [ copyScript ];
      };
  };

  testScript = ''
    startAll;
    $eris->waitForOpenPort(80);

    $client01->succeed("curl -f http://eris/v1/version");
    $client01->succeed("curl -f http://eris/v1/public-key");

    $client01->waitUntilSucceeds("${copyScript}/bin/copy-test ${testPkg}");
    $client01->succeed("nix run --store /root/test-store ${testPkg} -c psql --version")
  '';
}
