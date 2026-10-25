{ config, lib, ... }:

{
  config = lib.mkIf config.ostrium.image.disk {
    # make-disk-image with partitionTableType = "efi" labels the root partition
    # "nixos" and the EFI system partition "ESP".
    fileSystems."/" = {
      device = "/dev/disk/by-label/nixos";
      fsType = "ext4";
      autoResize = true;
      options = [ "noatime" ];
    };

    fileSystems."/boot" = {
      device = "/dev/disk/by-label/ESP";
      fsType = "vfat";
      # Readable so `bootctl list` / `ostrium-kernel current` work as ostrium;
      # writes still need root.
      options = [ "fmask=0022" "dmask=0022" ];
    };

    boot.loader.systemd-boot.enable = true;
    # Images are built without EFI variables; install systemd-boot as removable
    # media so the same image boots under OVMF, Proxmox and bare metal.
    boot.loader.efi.canTouchEfiVariables = false;
    boot.loader.systemd-boot.configurationLimit = 20;
    boot.loader.timeout = 2;
    boot.growPartition = true;
  };
}
