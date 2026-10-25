{ config, lib, pkgs, ... }:

let
  cfg = config.ostrium.kernel;

  packages = {
    lts = pkgs.linuxPackages;
    latest = pkgs.linuxPackages_latest;
    testing = pkgs.linuxPackages_testing;
  };

  # Everything except the boot default becomes a systemd-boot specialisation:
  # a frozen kernel snapshot you can select without rebuilding the image.
  snapshots = builtins.filter (k: k != cfg.default) cfg.choices;
in
{
  boot.kernelPackages = packages.${cfg.default};

  specialisation = lib.genAttrs snapshots (name: {
    configuration.boot.kernelPackages = lib.mkForce packages.${name};
  });

  # ostrium-kernel matches systemd-boot entries against these versions.
  environment.etc."ostrium/kernel-map.json".text = builtins.toJSON {
    inherit (cfg) default choices;
    versions = lib.listToAttrs (
      map (k: lib.nameValuePair k packages.${k}.kernel.version) cfg.choices
    );
  };
}
