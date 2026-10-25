# Compute image: LTS kernel by default with latest/testing as boot snapshots,
# rootless Podman storage on btrfs + zstd, no host mounts at all.
{
  config,
  lib,
  pkgs,
  ...
}:

{
  imports = [
    ../modules/base.nix
    ../modules/disk.nix
    ../modules/hardening.nix
    ../modules/kernel.nix
    ../modules/podman-policy.nix
    ../modules/control-panel.nix
    ../modules/compute-storage.nix
  ];

  ostrium.variant = "compute";
  ostrium.kernel.default = "lts";
  ostrium.kernel.choices = [
    "lts"
    "latest"
    "testing"
  ];
  ostrium.compute.containerDiskSize = lib.mkDefault "24G";

  virtualisation.diskSize = lib.mkDefault 40960;

  environment.systemPackages = with pkgs; [
    btrfs-progs
  ];
}
