# ostrium-linux

Three hardened NixOS images from one flake, all running **rootless Podman**
through a deny-by-default wrapper:

| Image | Purpose | Kernel | Root filesystem | Container storage |
|---|---|---|---|---|
| `ostrium-linux-dev` | developer install, desktop app's dev compose | latest mainline | ext4 | ext4 (workspace mounts + compose) |
| `ostrium-linux-compute` | container workloads on VMs | LTS, with latest/testing as boot snapshots | ext4 | **btrfs + zstd** (loopback, rootless graphroot) |
| `ostrium-linux-storage` | object storage VMs (RustFS) | LTS | ext4 (+ optional ext4 data disk) | ext4, mounts limited to `/srv/data` |

Every variant has qcow2, raw and ISO outputs for `x86_64-linux` and
`aarch64-linux`. CI builds x86 qcow2 and ISO plus arm ISO, emits an SPDX SBOM
and attests provenance.

```bash
nix build .#packages.x86_64-linux.compute-qcow2 -L
nix build .#packages.aarch64-linux.storage-iso   -L
make dev        # qcow2 + ISO for the dev image
make all        # all three variants
```

qcow2/raw go through `make-disk-image`, which boots a KVM guest, so those
builds need `/dev/kvm`. ISO builds do not. GitHub-hosted arm runners do not
expose KVM, which is why CI publishes arm ISO only; build arm qcow2 on a
KVM-capable arm64 machine.

`flake.lock` is committed, so every build uses the same nixpkgs tree. Update it
deliberately with `nix flake lock --update-input nixpkgs` and rebuild.

The images have no remote access by default. For VM deployments:

```nix
ostrium.ssh.enable = true;
ostrium.ssh.authorizedKeys = [ "ssh-ed25519 AAAA... you@laptop" ];
```

That turns on OpenSSH with password and root logins disabled.

---

## Why NixOS, not CachyOS or Omarchy

| | **NixOS (chosen)** | CachyOS | Omarchy |
|---|---|---|---|
| Kernel | mainline from nixpkgs-unstable; LTS/latest/testing selectable | Cachy-patched (BORE/sched-ext), not mainline | Arch kernel |
| ARM | first-class `aarch64-linux` | no (x86-only tuning) | no |
| x86-64-v3/v4 | `nixpkgs.hostPlatform.gcc.arch`, a build flag | its main selling point | yes (Arch) |
| Reproducibility | `flake.lock` pins every input | rolling pacman | rolling pacman + dotfiles |
| Hardening | declarative, reviewable, diffable | manual drift | manual, desktop-oriented |
| Supply chain | pinned nixpkgs, signed store paths, sandboxed builds | AUR build scripts | AUR |
| Image output | ISO, qcow2, raw from one config | manual | manual |

CachyOS optimizations are compiler flags and a patched scheduler; NixOS exposes
both without inheriting a rolling Arch base or losing ARM. Omarchy is an
opinionated Arch + Hyprland desktop — the wrong shape for a host with no GUI.

ISA tuning stays a build flag:

```nix
nixpkgs.hostPlatform = { system = "x86_64-linux"; gcc.arch = "x86-64-v3"; gcc.tune = "generic"; };
```

Only enable it when the whole fleet shares the baseline; it changes every store
hash and older CPUs fault.

---

## Kernel snapshots and the control panel

The **compute** image boots the LTS kernel and bakes two extra kernels into the
closure as systemd-boot specialisations:

```nix
ostrium.kernel.default = "lts";
ostrium.kernel.choices = [ "lts" "latest" "testing" ];
```

`modules/kernel.nix` maps `lts -> linuxPackages`, `latest ->
linuxPackages_latest`, `testing -> linuxPackages_testing`. Everything except the
default becomes a boot entry, so switching does not rebuild the image.

On the host:

```bash
ostrium-kernel list      # lts 6.18.x / latest 7.x / testing 7.x
ostrium-kernel current
sudo ostrium-kernel set latest
# reboot
```

`ostrium-control` is the interactive panel (kernel, containers, storage,
system). It reads the same `kernel-map.json`, so the toggle is just
`bootctl set-default` against the entry whose kernel path matches the chosen
version.

`dev` ships only the latest kernel and `storage` only LTS; on those images the
kernel menu says so.

---

## Storage layout

NixOS's `make-disk-image` asserts `fsType == "ext4"` whenever a partition table
is present, so a bootable btrfs root is not supported by the image builder. The
images therefore keep an ext4 root and put btrfs where it matters:

**compute** creates a sparse btrfs image on first boot
(`/var/lib/ostrium/containers.img`, 24 GiB by default), formats it with
`mkfs.btrfs -m single -d single`, and loop-mounts it at the rootless Podman
storage root (`/home/ostrium/.local/share/containers`) with:

```
compress=zstd:3,noatime,ssd,discard=async
```

A generated `~/.config/containers/storage.conf` sets `driver = "overlay"` plus
`fuse-overlayfs`, so image layers really do land on the compressed btrfs
filesystem. No mkfs at runtime beyond the first boot; the file is reused
afterwards.

**storage** uses ext4, and optionally a dedicated ext4 data disk:

```nix
ostrium.dataDisk = "/dev/disk/by-id/ata-...";   # mounted at /srv/data
```

Format it once with `mkfs.ext4 -L ostrium-data`, then set the option. `RustFS`
(S3-compatible, `pkgs.rustfs`) serves `/srv/data/rustfs` on port 9000. Its
access/secret keys are generated on first boot into
`/var/lib/ostrium/rustfs.env` (root:rustfs, 0640) and are never in the Nix
store. The console UI is disabled.

**dev** is ext4 with a writable rootfs and a `/home/ostrium/work` workspace.

---

## Rootless Podman policy

On every image `podman` **is** the policy wrapper (`ostrium-podman`); the
unwrapped podman is not in `PATH`. This is a guard rail for the account that
owns the machine, not a sandbox against a local attacker: anyone with a shell
can execute the store path of the real binary. Do not hand shell access to
untrusted users; use the compute image for workloads and a broker if you need
multi-tenant isolation.

| | dev | compute | storage |
|---|---|---|---|
| registries | allowlist | allowlist | allowlist |
| image reference | tag or digest | **digest only** | **digest only** |
| short names | resolve to docker.io | refused | refused |
| bind mounts | under `/home/ostrium/work` | **none** | under `/srv/data` |
| named volumes | yes | no | no |
| `--env` / `--env-file` | yes / workspace | no | no |
| `compose`, `network`, `volume` | yes | no | no |
| `build` | yes | **no** | **no** |
| rootfs | writable | read-only (fixed) | read-only (fixed) |
| default network | `pasta` | `none` | `none` |
| memory / pids / cpus | overridable | fixed at 2g / 256 / 2 | fixed at 2g / 256 / 2 |
| pull policy | `missing` | `never` | `never` |

Always refused on every variant: `--privileged`, `--cap-add`, `--device`,
`--pid/--ipc/--uts/--cgroupns`, `--pod`, `--userns=host`, `--security-opt` (except
`label=disable` on dev), `--apparmor`, `--selinux-opt`, `--group-add`,
`--env-host`, `--secret`, `--hooks-dir`, `--rootfs`, uid/gid remapping,
`--volumes-from`, `--runtime`, `--preserve-fds`, `--tls-verify`,
`--signature-policy`, auth/cert/log files, and any
path containing `.ssh`, `.gnupg`, `id_*`, `*.sock` or `SSH_AUTH_SOCK`.

The wrapper also adds, before Podman sees the command:

```
--userns=keep-id --security-opt no-new-privileges --cap-drop=all
--pids-limit=256 --memory=2g --cpus=2
```

and on compute/storage `--read-only --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m`.
Dev adds only `CHOWN,DAC_OVERRIDE,FOWNER,SETGID,SETUID` back (compose images
need them) and keeps a writable rootfs.

Images come only from:

```
ghcr.io/ostrium-labs/   docker.io/library/   quay.io/
registry.fedoraproject.org/   gcr.io/distroless/
```

`/etc/containers/policy.json` rejects every registry that is not explicitly
listed and requires a signature for `ghcr.io/ostrium-labs` via
`/etc/ostrium/cosign.pub`. Compute/storage disable
short-name resolution entirely (`unqualified-search-registries = []`,
`short-name-mode = "enforcing"`).

The ghcr rule is fail-closed: until you deploy the public key with
`ostrium.cosign.publicKey = builtins.readFile ./cosign.pub;`, pulls from
`ghcr.io/ostrium-labs` are refused instead of silently trusted.

### Examples

```bash
# compute / storage: digest only, no mounts
ostrium-podman pull ghcr.io/ostrium-labs/worker@sha256:<digest>
ostrium-podman run ghcr.io/ostrium-labs/worker@sha256:<digest>

# storage: the one allowed bind mount
ostrium-podman run -v /srv/data/jobs:/data ghcr.io/ostrium-labs/worker@sha256:<digest>

# dev: workspace bind mount and compose
ostrium-podman run -v /home/ostrium/work/app:/app docker.io/library/node:22
podman-compose -f /etc/ostrium/dev-compose.yaml up -d
```

`podman build` is accepted on the dev image only and must run from
`/home/ostrium/work`; `--file`, `--build-context` and absolute context paths
outside the workspace are refused. A Containerfile can still bind-mount host
paths in `RUN --mount`, and that is not something the wrapper can inspect.

Bypass attempts fail before Podman runs:

```bash
$ ostrium-podman run -v /etc:/host docker.io/library/alpine:3
ostrium-podman: refused: bind mount outside /home/ostrium/work: /etc
$ ostrium-podman run --privileged docker.io/library/alpine:3
ostrium-podman: refused: flag not allowed: --privileged
```

---

## Dev compose

`/etc/ostrium/dev-compose.yaml` is an example stack (Postgres + Redis) the
desktop app can start. Compose-created networks, named volumes, env vars and
`label=disable` are accepted on the dev image only. Bind mounts still have to
resolve inside `/home/ostrium/work`.

---

## Hardening trade-offs

`modules/hardening.nix` sets `mds=full,nosmt`, which disables SMT. That halves
peak throughput on shared hosts; drop the parameter there if you accept the
mitigation gap. Rootless Podman still needs unprivileged user namespaces
(`security.allowUserNamespaces = true`), and the wrapper is a guard rail for the
machine owner, not a sandbox against someone who already has a shell.

## Verification

```bash
make check                     # evaluate all outputs, both architectures
make test                      # wrapper policy regression tests
nix build .#packages.x86_64-linux.compute-qcow2 -L   # needs /dev/kvm
qemu-img info result/nixos.qcow2
```

`make check` passes `--no-build`, so it catches evaluation errors (including
aarch64) without building nine systems. The image targets do the real builds.

## First boot

Log in on the console as `ostrium` with password `ostrium`. The shipped
password is expired at first boot, so the login prompts for a new one; root is
locked. Change it before enabling SSH:

```bash
passwd
ostrium-control
podman images
systemctl --failed
```

The qcow2 images are UEFI (OVMF) with systemd-boot, because kernel switching
uses `bootctl`. Boot them with OVMF in libvirt/Proxmox.

## Repository layout

```
flake.nix                     three hosts x two arches x three formats
hosts/{dev,compute,storage}.nix
modules/base.nix              users, network, nix, base packages
modules/disk.nix              ext4 root + ESP + systemd-boot (skipped for ISO)
modules/hardening.nix         kernel cmdline, sysctl, LSM, audit, sudo-rs
modules/kernel.nix            LTS/latest/testing snapshots
modules/podman-policy.nix     policy config + wrapped podman
modules/compute-storage.nix   btrfs+zstd loopback for rootless storage
modules/control-panel.nix     ostrium-kernel / ostrium-control
files/ostrium-podman          the deny-by-default wrapper
files/ostrium-kernel          kernel snapshot selector
files/ostrium-control         TUI panel
files/dev-compose.yaml        example stack for the desktop app
tests/policy.sh               wrapper policy regression tests
```
