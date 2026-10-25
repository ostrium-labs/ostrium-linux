{
  description = "ostrium-linux — dev, compute and storage images (rootless Podman)";

  inputs = {
    # Unstable tracks mainline within days; the lock file pins the exact tree.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixos-generators,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      hosts = {
        dev = ./hosts/dev.nix;
        compute = ./hosts/compute.nix;
        storage = ./hosts/storage.nix;
      };

      mkSystem = system: host: nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          host
          # cptofs starts its LKL kernel with a hard-coded 100 MiB of RAM. The
          # compute image carries three kernels and their initrds, and cptofs
          # panics with an out-of-memory kernel log at that size. Raise the LKL
          # heap for the image builder only.
          {
            nixpkgs.overlays = [
              (final: prev: {
                lkl = prev.lkl.overrideAttrs (old: {
                  postPatch = (old.postPatch or "") + ''
                    sed -i 's/"mem=100M"/"mem=2048M"/' tools/lkl/cptofs.c
                  '';
                });
              })
            ];
          }
        ];
      };

      # NixOS's make-disk-image only allows ext4 with a partition table, so the
      # root is ext4 everywhere. btrfs is used for Podman storage on compute.
      mkDisk =
        system: host: format:
        let
          sys = mkSystem system host;
        in
        import "${nixpkgs}/nixos/lib/make-disk-image.nix" {
          inherit (sys) config lib pkgs;
          inherit format;
          partitionTableType = "efi";
          diskSize = sys.config.virtualisation.diskSize;
          # Three kernels plus specialisations must fit on the ESP.
          bootSize = "512M";
          # cptofs needs host RAM for the closure; the default 1 GiB OOMs on
          # the compute image with three kernels.
          memSize = 4096;
        };

      mkIso = system: host: nixos-generators.nixosGenerate {
        inherit system;
        format = "iso";
        modules = [
          host
          (
            { config, lib, ... }:
            {
              # Live media: no disk layout, one kernel, no storage daemon.
              ostrium.image.disk = lib.mkForce false;
              ostrium.kernel.choices = lib.mkForce [ config.ostrium.kernel.default ];
              ostrium.rustfs.enable = lib.mkForce false;
            }
          )
        ];
      };
    in
    {
      nixosConfigurations = nixpkgs.lib.mapAttrs (name: host: mkSystem "x86_64-linux" host) hosts;

      packages = nixpkgs.lib.genAttrs systems (
        system:
        nixpkgs.lib.foldl' (
          acc: name:
          acc
          // {
            "${name}-qcow2" = mkDisk system hosts.${name} "qcow2";
            "${name}-raw" = mkDisk system hosts.${name} "raw";
            "${name}-iso" = mkIso system hosts.${name};
          }
        ) { } (builtins.attrNames hosts)
      );
    };
}
