{ config, pkgs, ... }:

{
  imports =
    [ # Include the results of the Packet.net hardware scan.
      ./packet/packet.nix

      # Include the Eris NixOS module
      ../module.nix
    ];

  # Use the GRUB 2 boot loader.
  boot.loader.grub.enable = true;
  boot.loader.grub.version = 2;

  # Basic program configuration
  programs.bash.enableCompletion = true;
  programs.mtr.enable = true;
  services.openssh.enable = true;

  environment.systemPackages = with pkgs; [
    wget vim
  ];

  # Minimize the configuration a bit for a headless server
  boot.loader.grub.splashImage = null;
  sound.enable = false;
  environment.noXlibs = true;
  i18n.supportedLocales = [ (config.i18n.defaultLocale + "/UTF-8") ];

  # Use Google's Public, Leap-Smeared NTP servers
  #   https://developers.google.com/time/smear
  # Also, use Chrony for timekeeping
  time.timeZone = "America/Chicago";
  networking.timeServers =
    [ "time1.google.com"
      "time2.google.com"
      "time3.google.com"
      "time4.google.com"
    ];
  services.chrony.enable = true;
  services.chrony.extraConfig = ''
    rtcsync
  '';

  # Networking configuration
  networking.firewall.allowedTCPPorts = [ 22 80 443 ];
  boot.kernel.sysctl."net.ipv4.tcp_congestion_control" = "bbr";

  # Eris configuration
  services.eris-git =
    let
      cloudflareIPs = with builtins;
        replaceStrings [ "\n" ] [ " " ] (readFile ./cloudflare-ips.txt);

      erisConfig = pkgs.writeText "eris.conf" ''
        {
          listen  => [ 'http://[::]:80', 'https://[::]:443' ],
          proxy => 1,

          signing => {
            host    => 'cache.z0ne.pw-1',
            private => '/etc/eris/sign.sk',
          },
        }
      '';
    in { enable = true;
         configFile = "${erisConfig}";
         ipAddressAllow = cloudflareIPs;
         ipAddressDeny = "any";
       };

  # -- El fin

  # This value determines the NixOS release with which your system is to be
  # compatible, in order to avoid breaking some software such as database
  # servers. You should change this only after NixOS release notes say you
  # should.
  system.stateVersion = "18.09"; # Did you read the comment?
}
