# Shared base for all three images: no desktop, no compilers beyond what a
# variant adds, no remote access by default.
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    ./options.nix
    "${modulesPath}/profiles/minimal.nix"
    "${modulesPath}/profiles/qemu-guest.nix"
  ];

  system.stateVersion = "25.11";

  networking.hostName = lib.mkDefault "ostrium";
  networking.useNetworkd = true;
  systemd.network.networks."10-dhcp" = lib.mkDefault {
    matchConfig.Name = "en* eth*";
    networkConfig.DHCP = "yes";
  };
  networking.firewall.enable = true;
  networking.nftables.enable = true;

  time.timeZone = "UTC";
  i18n.defaultLocale = "en_US.UTF-8";

  services.openssh = lib.mkIf config.ostrium.ssh.enable {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };
  users.users.ostrium.openssh.authorizedKeys.keys = config.ostrium.ssh.authorizedKeys;
  services.avahi.enable = false;
  services.printing.enable = false;
  services.xserver.enable = false;
  services.resolved.enable = true;
  services.resolved.settings.Resolve = {
    DNSSEC = "allow-downgrade";
    DNSOverTLS = "opportunistic";
    MulticastDNS = false;
  };

  # podman in rootless mode needs the fuse and overlay modules present early.
  boot.kernelModules = [
    "fuse"
    "overlay"
  ];

  users.mutableUsers = lib.mkDefault true;
  users.users.ostrium = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    initialPassword = lib.mkDefault "ostrium";
    subUidRanges = [
      {
        startUid = 100000;
        count = 65536;
      }
    ];
    subGidRanges = [
      {
        startGid = 100000;
        count = 65536;
      }
    ];
  };
  users.users.root.hashedPassword = "!";

  systemd.services.ostrium-first-boot = {
    description = "Expire the shipped password exactly once";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-user-sessions.service" ];
    unitConfig.ConditionPathExists = "!/var/lib/ostrium/.password-expired";
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "ostrium";
      RemainAfterExit = true;
    };
    script = ''
      ${pkgs.shadow}/bin/chage -d 0 ostrium || true
      touch /var/lib/ostrium/.password-expired
    '';
  };

  environment.etc."ostrium/variant".text = config.ostrium.variant;

  # Runtime tools only. Variants add their own toolchains.
  # Deliberately no crun/conmon/buildah in PATH: they can start OCI containers
  # without going through the policy wrapper. Podman finds its own runtime in
  # the store.
  environment.systemPackages = with pkgs; [
    fuse-overlayfs
    slirp4netns
    passt
    skopeo
    cosign
    jq
    curl
    git
    openssl
    vim
    less
    htop
    procps
  ];

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    allowed-users = lib.mkDefault [ "root" ];
    trusted-users = [ "root" ];
    auto-optimise-store = true;
  };
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };
  nix.optimise.automatic = true;
  system.autoUpgrade.enable = false;

  boot.tmp.useTmpfs = true;
  boot.tmp.tmpfsSize = "1G";

  documentation.enable = lib.mkDefault false;
  documentation.nixos.enable = lib.mkDefault false;

  services.journald.settings.Journal.SystemMaxUse = "200M";
}
