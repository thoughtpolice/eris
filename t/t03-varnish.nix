{ pkgs, ... }:

let
  testPkg = pkgs.writeShellScriptBin "varnish-test" ''
    echo hello world
  '';

  configFile = pkgs.writeText "eris.conf" ''
    {
      listen => ['http://[::1]:5000'],
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

        services.varnish = {
          enable = true;
          http_address = "0.0.0.0:80";
          config = ''
            vcl 4.0;

            backend eris {
              .host = "::1";
              .port = "5000";
            }
          '';
        };

        networking.firewall.allowedTCPPorts = [ 80 ];
        environment.systemPackages = [ testPkg ];
      };

    client01 = { config, pkgs, ... }:
      { imports = [];

        nix.requireSignedBinaryCaches = false;
        nix.binaryCaches = [ "http://eris" ];
      };
  };

  testScript = ''
    startAll;
    $eris->waitForOpenPort(80);
    $eris->waitForOpenPort(5000);

    $client01->succeed("curl -f http://eris/v1/version");
    $client01->succeed("curl -f http://eris/nix-cache-info");
    $client01->fail("curl -f http://eris/v1/public-key");

    $client01->waitUntilSucceeds("nix copy --from http://eris/ ${testPkg}");
    $client01->succeed("${testPkg}/bin/varnish-test");
  '';
}
