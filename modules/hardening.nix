# Kernel, sysctl, LSM and audit hardening. Everything here is declarative and
# ends up in the signed system closure.
{ config, lib, pkgs, ... }:

{
  # --- kernel command line -------------------------------------------------
  boot.kernelParams = [
    "slab_nomerge"
    "init_on_alloc=1"
    "init_on_free=1"
    "page_alloc.shuffle=1"
    "randomize_kstack_offset=on"
    "vsyscall=none"
    "debugfs=off"
    "oops=panic"
    "audit=1"
    "pti=on"
    "spectre_v2=on"
    "spec_store_bypass_disable=on"
    "tsx=off"
    # nosmt halves capacity on shared hosts; drop it if you accept the risk.
    "mds=full,nosmt"
    "l1tf=full,force"
    "kvm.nx_huge_pages=force"
    "efi=disable_early_pci_dma"
  ];

  # Protocols nobody on this host needs. Loading them is a prerequisite for a
  # long list of kernel CVEs.
  boot.blacklistedKernelModules = [ "dccp" "sctp" "rds" "tipc" "cramfs" "freevxfs" "jffs2" ];

  # --- sysctl --------------------------------------------------------------
  boot.kernel.sysctl = {
    "kernel.kptr_restrict" = 2;
    "kernel.dmesg_restrict" = 1;
    "kernel.unprivileged_bpf_disabled" = 1;
    "kernel.yama.ptrace_scope" = 3;
    "kernel.perf_event_paranoid" = 3;
    "kernel.kexec_load_disabled" = 1;
    "kernel.sysrq" = 0;
    "kernel.randomize_va_space" = 2;
    "net.core.bpf_jit_harden" = 2;
    "fs.protected_hardlinks" = 1;
    "fs.protected_symlinks" = 1;
    "fs.protected_fifos" = 2;
    "fs.protected_regular" = 2;
    "fs.suid_dumpable" = 0;
    "net.ipv4.conf.all.rp_filter" = 1;
    "net.ipv4.conf.default.rp_filter" = 1;
    "net.ipv4.tcp_syncookies" = 1;
    "net.ipv4.conf.all.accept_redirects" = 0;
    "net.ipv4.conf.all.send_redirects" = 0;
    "net.ipv4.conf.all.accept_source_route" = 0;
    "net.ipv6.conf.all.accept_redirects" = 0;
    "net.ipv6.conf.all.accept_source_route" = 0;
    "net.ipv4.icmp_echo_ignore_broadcasts" = 1;
    "net.ipv4.conf.all.log_martians" = 1;
  };

  # --- LSMs and privilege boundaries --------------------------------------
  security.apparmor.enable = true;
  security.apparmor.packages = [ pkgs.apparmor-profiles ];

  # Rootless Podman needs unprivileged user namespaces. Do NOT set
  # security.allowUserNamespaces = false here: it silently breaks `podman run`.
  security.allowUserNamespaces = true;

  # protectKernelImage also flips kernel.modules_disabled, which would break
  # first-use module loading for /dev/fuse. kexec is disabled via sysctl instead.
  security.forcePageTableIsolation = true;
  security.virtualisation.flushL1DataCache = "always";

  security.sudo.enable = false;
  security.sudo-rs.enable = true;

  systemd.coredump.enable = false;

  # --- audit ---------------------------------------------------------------
  security.auditd.enable = true;
  security.audit.enable = true;
  security.audit.rules = [
    "-w /etc/passwd -p wa -k identity"
    "-w /etc/shadow -p wa -k identity"
    "-w /etc/group -p wa -k identity"
    "-w /etc/sudoers -p wa -k privileged"
    "-w /etc/ostrium -p wa -k ostrium-config"
    "-a always,exit -F arch=b64 -S mount -S umount2 -k mount"
    "-a always,exit -F arch=b64 -S init_module -S finit_module -k modules"
  ];
}
