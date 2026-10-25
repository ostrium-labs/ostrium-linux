{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.ostrium;
  isDev = cfg.variant == "dev";
  isStorage = cfg.variant == "storage";

  policy = pkgs.writeShellScriptBin "ostrium-podman" (
    builtins.readFile ../files/ostrium-podman
  );

  # Shadow the podman package's bin/podman. The NixOS module keeps ownership of
  # the package (runtimes, systemd units, extraPackages); this wrapper just has
  # a lower meta.priority, so buildEnv links it to /run/current-system/sw/bin.
  podman = pkgs.writeShellScriptBin "podman" ''
    export PODMAN_BIN=${config.virtualisation.podman.package}/bin/podman
    export PATH=/run/wrappers/bin:$PATH
    exec ${policy}/bin/ostrium-podman "$@"
  '';
in
{
  virtualisation.podman = {
    enable = true;
    dockerCompat = false;
    dockerSocket.enable = false;
  };

  # The module ships a socket-activated `podman system service`. That service
  # speaks the libpod API directly and would bypass the wrapper, so disable the
  # socket and the service. Rootless podman does not need them.
  systemd.sockets.podman.enable = false;
  systemd.services.podman.enable = false;
  systemd.user.sockets.podman.enable = false;
  systemd.user.services.podman.enable = false;

  environment.systemPackages = [
    (lib.setPrio 1 podman)
    policy
  ];

  # Read by files/ostrium-podman.
  environment.etc."ostrium/podman-policy.conf".text = ''
    MODE=${cfg.variant}
    WORKSPACE=${
      if isDev then
        cfg.podman.workspace
      else if isStorage then
        cfg.podman.dataDir
      else
        "/nonexistent"
    }
  '';

  # Dev compose uses short names; compute and storage must be explicit and
  # digest-pinned.
  environment.etc."containers/registries.conf.d/99-ostrium.conf".text =
    if isDev then
      ''
        unqualified-search-registries = ["docker.io"]
        short-name-mode = "permissive"
      ''
    else
      ''
        unqualified-search-registries = []
        short-name-mode = "enforcing"
      '';

  # virtualisation.containers owns /etc/containers/policy.json, so set the
  # option instead of writing the file (two definitions would conflict).
  virtualisation.containers.policy = builtins.fromJSON (
    builtins.readFile ../files/policy.json
  );

  environment.etc."ostrium/cosign.pub" = lib.mkIf (cfg.cosign.publicKey != "") {
    text = cfg.cosign.publicKey;
    mode = "0444";
  };

  users.users.ostrium.subUidRanges = lib.mkDefault [
    {
      startUid = 100000;
      count = 65536;
    }
  ];
  users.users.ostrium.subGidRanges = lib.mkDefault [
    {
      startGid = 100000;
      count = 65536;
    }
  ];
}
