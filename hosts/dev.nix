# Developer image: latest kernel, workspace-scoped container mounts, compose,
# and a real toolchain.
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
  ];

  ostrium.variant = "dev";
  ostrium.kernel.default = "latest";
  ostrium.kernel.choices = [ "latest" ];
  ostrium.podman.workspace = "/home/ostrium/work";

  virtualisation.diskSize = lib.mkDefault 16384;

  environment.systemPackages = with pkgs; [
    gcc
    gnumake
    pkg-config
    rustc
    cargo
    nodejs
    pnpm
    python3
    just
    ripgrep
    fd
    neovim
    tmux
    podman-compose
  ];

  # Interactive dev work needs ptrace; keep the rest of the hardening as-is.
  boot.kernel.sysctl."kernel.yama.ptrace_scope" = lib.mkForce 1;

  nix.settings.allowed-users = [ "@wheel" ];

  systemd.tmpfiles.rules = [
    "d /home/ostrium/work 0755 ostrium users -"
  ];

  environment.etc."ostrium/dev-compose.yaml".source = ../files/dev-compose.yaml;
}
