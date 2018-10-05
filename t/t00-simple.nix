{ pkgs, ... }:

let
  testPkg = pkgs.writeShellScriptBin "simple00-test" ''
    echo hello world
  '';

  configFile = pkgs.writeText "eris.conf" ''
    {
      listen => ['http://[::]:8080'],
    }
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

        networking.firewall.allowedTCPPorts = [ 8080 ];
        environment.systemPackages = [ testPkg ];
      };

    client01 = { config, pkgs, ... }:
      { imports = [];

        nix.requireSignedBinaryCaches = false;
        nix.binaryCaches = [ "http://eris:8080" ];
      };
  };

  testScript = ''
    startAll;
    $eris->waitForOpenPort(8080);

    $client01->succeed("curl -f http://eris:8080/v1/version");
    $client01->succeed("curl -f http://eris:8080/nix-cache-info");
    $client01->fail("curl -f http://eris:8080/v1/public-key");

    $client01->waitUntilSucceeds("nix copy --from http://eris:8080/ ${testPkg}");
    $client01->succeed("${testPkg}/bin/simple00-test");
  '';
}
