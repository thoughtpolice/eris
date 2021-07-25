{ config, pkgs, lib, ... }:

with builtins;
with lib;

let
  cfg = config.services.eris-git;

  eris = pkgs.perlPackages.callPackage ./. { };
in
{
  options = {
    services.eris-git = {
      enable = mkEnableOption "Eris: the simple, flexible Nix binary cache";

      configFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "The path to the Eris configuration file.";
      };

      debug = mkOption {
        type = types.bool;
        default = false;
        description = "Enable request/response debugging for the server";
      };

      ipAddressAllow = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "List of IP addresses to allow to the listening ports";
      };

      ipAddressDeny = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "List of IP addresses to deny to the listening ports";
      };
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [ eris ];

    systemd.services.eris-git = {
      description = "eris binary cache server";
      documentation = [ "man:eris(8)" "https://thoughtpolice.github.io/eris" ];

      requires = [ "nix-daemon.socket" ];
      after    = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      path = [ config.nix.package.out ];
      environment.NIX_REMOTE = "daemon";
      environment.ERIS_PID_FILE = "/run/eris/eris.pid";
      environment.ERIS_CONFIG = mkIf (cfg.configFile != null) cfg.configFile;
      environment.LIBEV_FLAGS = "4"; # go ahead and mandate epoll(2)

      environment.MOJO_LOG_SHORT = mkIf (!cfg.debug) "1";
      environment.MOJO_MODE = mkIf cfg.debug "development";

      # Note: it's important to set this for nix-store, because it wants to use
      # $HOME in order to use a temporary cache dir. bizarre failures will occur
      # otherwise
      environment.HOME = "/run/eris";

      serviceConfig = {
        ExecStart = "${eris}/bin/eris";
        Type="forking";
        Restart = "always";
        RestartSec = "5s";

        DynamicUser  = true;
        ProtectHome = "yes";

        ConfigurationDirectory = "eris";
        RuntimeDirectory = "eris";
        PIDFile = "/run/eris/eris.pid";
        KillMode = "process";

        SupplementaryGroups="adm";
        TemporaryFileSystem="/etc:ro";
        BindReadOnlyPaths="/etc/eris";

        IPAccounting = true;
        IPAddressAllow = mkIf (cfg.ipAddressAllow != null) cfg.ipAddressAllow;
        IPAddressDeny  = mkIf (cfg.ipAddressDeny  != null) cfg.ipAddressDeny;
        LimitNOFILE = 65536;

        # TODO FIXME: This should really be replaced with socket activation...
        AmbientCapabilities="cap_net_bind_service";
      };
    };
  };
}
