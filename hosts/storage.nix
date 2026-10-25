# Storage image: ext4 root and optional ext4 data disk, RustFS on port 9000.
# Containers may only mount paths under /srv/data.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.ostrium;
in
{
  imports = [
    ../modules/base.nix
    ../modules/disk.nix
    ../modules/hardening.nix
    ../modules/kernel.nix
    ../modules/podman-policy.nix
    ../modules/control-panel.nix
  ];

  ostrium.variant = "storage";
  ostrium.kernel.default = "lts";
  ostrium.kernel.choices = [ "lts" ];
  ostrium.rustfs.enable = true;

  virtualisation.diskSize = lib.mkDefault 20480;

  fileSystems."/srv/data" = lib.mkIf (cfg.dataDisk != null) {
    device = cfg.dataDisk;
    fsType = "ext4";
    options = [
      "noatime"
      "nodiratime"
    ];
  };

  systemd.tmpfiles.rules = [
    "d /srv/data 0755 root root -"
  ];

  environment.systemPackages = with pkgs; [
    e2fsprogs
    smartmontools
  ];

  # --- RustFS -------------------------------------------------------------
  # The nixpkgs module sets User=rustfs but does not create the account.
  users.groups.rustfs = { };
  users.users.rustfs = {
    isSystemUser = true;
    group = "rustfs";
  };

  services.rustfs = lib.mkIf cfg.rustfs.enable {
    enable = true;
    settings = {
      RUSTFS_VOLUMES = cfg.rustfs.volumes;
      RUSTFS_CONSOLE_ENABLE = "false";
    };
    environmentFile = "/var/lib/ostrium/rustfs.env";
  };

  systemd.services.ostrium-rustfs-secrets = lib.mkIf (cfg.rustfs.enable && config.services.rustfs.enable) {
    description = "Generate RustFS credentials on first boot";
    wantedBy = [ "multi-user.target" ];
    before = [ "rustfs.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [
      pkgs.openssl
      pkgs.coreutils
    ];
    script = ''
      install -d -m 0750 /var/lib/ostrium
      if [ ! -s /var/lib/ostrium/rustfs.env ]; then
        umask 027
        {
          echo "RUSTFS_ACCESS_KEY=$(openssl rand -hex 16)"
          echo "RUSTFS_SECRET_KEY=$(openssl rand -hex 32)"
        } > /var/lib/ostrium/rustfs.env
      fi
      chown root:rustfs /var/lib/ostrium/rustfs.env
      chmod 0640 /var/lib/ostrium/rustfs.env
    '';
  };

  # Create the volume whether or not a separate data disk is mounted: without
  # one, /srv/data is a root-owned directory on the root filesystem and RustFS
  # (running as the rustfs user) cannot create its volume itself.
  systemd.services.ostrium-data-perms = lib.mkIf (cfg.rustfs.enable && config.services.rustfs.enable) {
    description = "Create the RustFS volume";
    wantedBy = [ "multi-user.target" ];
    requires = lib.optional (cfg.dataDisk != null) "srv-data.mount";
    after = [ "local-fs.target" ] ++ lib.optional (cfg.dataDisk != null) "srv-data.mount";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      install -d -m 0750 -o rustfs -g rustfs ${cfg.rustfs.volumes}
    '';
  };

  systemd.services.rustfs = lib.mkIf (cfg.rustfs.enable && config.services.rustfs.enable) {
    requires = [
      "ostrium-rustfs-secrets.service"
      "ostrium-data-perms.service"
    ] ++ lib.optional (cfg.dataDisk != null) "srv-data.mount";
    after = [
      "ostrium-rustfs-secrets.service"
      "ostrium-data-perms.service"
    ] ++ lib.optional (cfg.dataDisk != null) "srv-data.mount";
  };

  networking.firewall.allowedTCPPorts = [ 9000 ];
}
