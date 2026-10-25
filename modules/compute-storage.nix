# Rootless Podman storage on btrfs + zstd.
#
# NixOS's make-disk-image only supports ext4 when a partition table is present
# (it asserts fsType == "ext4" for anything but partitionTableType = "none"),
# so the root stays ext4 and container storage lives on a btrfs filesystem in a
# sparse file. The file is loop-mounted at the rootless storage root, which is
# what actually gets compressed.
{ config, lib, pkgs, ... }:

let
  cfg = config.ostrium.compute;
  mount = "/home/ostrium/.local/share/containers";
in
{
  systemd.services.ostrium-containers-fs = {
    description = "Create the btrfs container storage image";
    wantedBy = [ "multi-user.target" ];
    before = [ "home-ostrium-.local-share-containers.mount" ];
    path = [
      pkgs.btrfs-progs
      pkgs.util-linux
      pkgs.coreutils
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -eu
      img=/var/lib/ostrium/containers.img
      install -d -m 0755 /var/lib/ostrium
      install -d -m 0700 -o ostrium -g users ${mount}
      if [ ! -s "$img" ]; then
        truncate -s ${cfg.containerDiskSize} "$img"
        mkfs.btrfs -f -L ostrium-containers -m single -d single "$img"
      elif ! blkid -t TYPE=btrfs "$img" >/dev/null 2>&1; then
        echo "ostrium-containers-fs: $img exists but is not btrfs; refusing to reformat" >&2
        exit 1
      fi
    '';
  };

  fileSystems."${mount}" = {
    device = "/var/lib/ostrium/containers.img";
    fsType = "btrfs";
    neededForBoot = false;
    options = [
      "loop"
      "compress=zstd:3"
      "noatime"
      "ssd"
      "discard=async"
      "x-systemd.requires=ostrium-containers-fs.service"
      "x-systemd.after=ostrium-containers-fs.service"
    ];
  };

  systemd.services.ostrium-containers-perms = {
    description = "Give ostrium ownership of the btrfs container storage";
    wantedBy = [ "multi-user.target" ];
    requires = [ "home-ostrium-.local-share-containers.mount" ];
    after = [ "home-ostrium-.local-share-containers.mount" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      chown ostrium:users ${mount}
      chmod 0700 ${mount}
    '';
  };

  # Rootless Podman reads this before it reads /etc/containers/storage.conf.
  # Depend on the users activation so the home directory already exists (and is
  # owned by ostrium) before we create anything below it.
  system.activationScripts.ostrium-podman-storage = {
    deps = [ "users" ];
    text = ''
      install -d -m 0755 -o ostrium -g users /home/ostrium/.config
      install -d -m 0700 -o ostrium -g users /home/ostrium/.config/containers
      cat > /home/ostrium/.config/containers/storage.conf <<'EOF'
[storage]
driver = "overlay"
mount_program = "/run/current-system/sw/bin/fuse-overlayfs"
graphroot = "${mount}/storage"
EOF
      chown ostrium:users /home/ostrium/.config/containers/storage.conf
      chmod 0600 /home/ostrium/.config/containers/storage.conf
    '';
  };
}
