{ lib, ... }:

{
  options.ostrium = {
    variant = lib.mkOption {
      type = lib.types.enum [ "dev" "compute" "storage" ];
      default = "compute";
      description = "Which ostrium-linux image this host is.";
    };

    image.disk = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Emit a partitioned disk layout. Disable when building live ISO media.";
    };

    podman.workspace = lib.mkOption {
      type = lib.types.str;
      default = "/home/ostrium/work";
      description = "The only host directory a container may bind-mount (dev image).";
    };

    podman.dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/srv/data";
      description = "The only host directory a container may bind-mount (storage image).";
    };

    kernel = {
      default = lib.mkOption {
        type = lib.types.enum [ "lts" "latest" "testing" ];
        default = "lts";
      };
      choices = lib.mkOption {
        type = lib.types.listOf (lib.types.enum [ "lts" "latest" "testing" ]);
        default = [ "lts" ];
        description = "Kernel snapshots baked into the image. Extra choices become systemd-boot specialisations.";
      };
    };

    compute = {
      containerDiskSize = lib.mkOption {
        type = lib.types.str;
        default = "24G";
        description = "Sparse btrfs image backing rootless Podman storage on the compute image.";
      };
    };

    dataDisk = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional block device for /srv/data on the storage image, e.g. /dev/disk/by-id/....";
    };

    rustfs = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };
      volumes = lib.mkOption {
        type = lib.types.str;
        default = "/srv/data/rustfs";
      };
    };

    ssh = {
      enable = lib.mkEnableOption "key-only OpenSSH for VM deployments";
      authorizedKeys = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Public keys installed for the ostrium user.";
      };
    };

    cosign.publicKey = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = ''
        Cosign public key written to /etc/ostrium/cosign.pub. Until this is set,
        pulling from ghcr.io/ostrium-labs fails closed (policy.json requires a
        signature for that registry).
      '';
    };
  };
}
