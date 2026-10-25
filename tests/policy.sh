#!/usr/bin/env bash
# Policy regression tests for files/ostrium-podman.
#
# The wrapper is the security boundary for `podman` on every image, so these
# tests exercise it against a fake podman binary and assert both the refusals
# and the flags the wrapper injects. Run with: bash tests/policy.sh
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WRAPPER=$ROOT/files/ostrium-podman
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/work/sub" "$TMP/work/.ssh" "$TMP/srv/data/x"
touch "$TMP/work/env"
cat > "$TMP/bin/podman" <<'EOF'
#!/usr/bin/env bash
printf 'PODMAN'
for arg in "$@"; do printf ' [%s]' "$arg"; done
printf '\n'
EOF
chmod +x "$TMP/bin/podman"

fail=0
pass=0

policy() {
  local mode=$1 workspace=/nonexistent
  case $mode in
    dev) workspace=$TMP/work ;;
    storage) workspace=$TMP/srv ;;
  esac
  printf 'MODE=%s\nWORKSPACE=%s\n' "$mode" "$workspace" > "$TMP/policy.conf"
}

wrap() {
  ( cd "$TMP" && OSTRIUM_PODMAN_POLICY=$TMP/policy.conf PODMAN_BIN=$TMP/bin/podman "$WRAPPER" "$@" )
}

ok() {
  local desc=$1 mode=$2 expect=$3
  shift 3
  policy "$mode"
  local out
  if out=$(wrap "$@" 2>&1) && [[ $out == *"$expect"* ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL (allow): %s\n  args: %s\n  out: %s\n' "$desc" "$*" "$out"
  fi
}

no() {
  local desc=$1 mode=$2
  shift 2
  policy "$mode"
  local out
  if out=$(wrap "$@" 2>&1); then
    fail=$((fail + 1))
    printf 'FAIL (refuse): %s\n  args: %s\n  out: %s\n' "$desc" "$*" "$out"
  elif [[ $out != *refused* ]]; then
    fail=$((fail + 1))
    printf 'FAIL (message): %s\n  out: %s\n' "$desc" "$out"
  else
    pass=$((pass + 1))
  fi
}

# dev: tags, workspace mounts, env, compose and build are allowed.
ok "dev pulls tags"                 dev  'PODMAN [pull] [docker.io/library/alpine:3]' pull docker.io/library/alpine:3
ok "dev runs tags"                  dev  '[--network=pasta]'                      run docker.io/library/alpine:3
ok "dev bind mount in workspace"    dev  '[-v]'                                   run -v "$TMP/work/sub:/app" docker.io/library/alpine:3
ok "dev --mount in workspace"       dev  'PODMAN [run]'                           run --mount type=bind,src="$TMP/work",dst=/app docker.io/library/alpine:3
ok "dev env"                        dev  'PODMAN [run]'                           run -e FOO=bar docker.io/library/alpine:3
ok "dev env-file workspace"         dev  'PODMAN [run]'                           run --env-file "$TMP/work/env" docker.io/library/alpine:3
no "dev env-file outside"           dev run --env-file ../../etc/passwd docker.io/library/alpine:3
ok "dev label=disable"              dev  'PODMAN [run]'                           run --security-opt label=disable docker.io/library/alpine:3
ok "dev compose"                    dev  'PODMAN [compose]'                       compose up -d
ok "dev build"                      dev  'PODMAN [build]'                         build -t app .
ok "dev image build alias"          dev  'PODMAN [build]'                          image build -t app .
ok "dev volume create"              dev  'PODMAN [volume] [create]'               volume create pgdata
ok "dev overrides resources"        dev  '[--memory=4g]'                          run --memory=4g docker.io/library/alpine:3

# compute: digest-only, no mounts/env/compose, fixed rootfs and resources.
ok "compute pulls digest"           compute 'PODMAN [pull]'                      pull ghcr.io/ostrium-labs/worker@sha256:deadbeef
ok "compute image pull digest"      compute 'PODMAN [pull]'                      image pull ghcr.io/ostrium-labs/worker@sha256:deadbeef
ok "compute runs digest readonly"   compute '[--read-only]'                     run ghcr.io/ostrium-labs/worker@sha256:deadbeef
ok "compute defaults to no net"     compute '[--network=none]'                   run ghcr.io/ostrium-labs/worker@sha256:deadbeef
ok "compute allows private net"     compute '[--network=private]'               run --network=private ghcr.io/ostrium-labs/worker@sha256:deadbeef
no "compute pulls tags"             compute pull ghcr.io/ostrium-labs/worker:latest
no "compute runs tags"              compute run ghcr.io/ostrium-labs/worker:latest
no "compute bind mount"             compute run -v "$TMP/work:/app" ghcr.io/ostrium-labs/worker@sha256:deadbeef
no "compute env"                    compute run -e FOO=bar ghcr.io/ostrium-labs/worker@sha256:deadbeef
no "compute compose"                compute compose up -d
no "compute build"                  compute build -t app .
no "volume driver binds host"       dev volume create -o device=/etc -o type=none -o o=bind etc
no "build --file outside"           dev build --file=/etc/passwd .
no "build --file outside (short)"   dev build -f ../../etc/passwd .
no "build context outside"          dev build ../..
no "compute resource override"      compute run --memory=8g ghcr.io/ostrium-labs/worker@sha256:deadbeef
no "compute short memory override"  compute run -m8g ghcr.io/ostrium-labs/worker@sha256:deadbeef
no "compute cgroup override"        compute run --cgroup-conf memory.max=8g ghcr.io/ostrium-labs/worker@sha256:deadbeef
no "compute security-opt"           compute run --security-opt label=disable ghcr.io/ostrium-labs/worker@sha256:deadbeef
no "compute env-file"               compute run --env-file /etc/passwd ghcr.io/ostrium-labs/worker@sha256:deadbeef

# storage: only /srv/data may be mounted.
ok "storage mounts /srv/data"       storage 'PODMAN [run]'                        run -v "$TMP/srv/data/x:/data" ghcr.io/ostrium-labs/worker@sha256:deadbeef
no "storage mounts home"            storage run -v "$HOME:/data" ghcr.io/ostrium-labs/worker@sha256:deadbeef

# Always refused.
no "privileged"                     dev run --privileged docker.io/library/alpine:3
no "cap-add"                        dev run --cap-add=SYS_ADMIN docker.io/library/alpine:3
no "host network"                   dev run --network=host docker.io/library/alpine:3
no "host pid"                       dev run --pid=host docker.io/library/alpine:3
no "userns host"                    dev run --userns=host docker.io/library/alpine:3
no "device"                         dev run --device /dev/kvm docker.io/library/alpine:3
no "relative bind source"           dev run --mount type=bind,src=work,dst=/x docker.io/library/alpine:3
no "duplicate bind source"          dev run --mount "type=bind,src=$TMP/work,dst=/x,src=/etc" docker.io/library/alpine:3
no "ssh key volume"                 dev run -v "$TMP/work/.ssh:/keys" docker.io/library/alpine:3
no "docker socket"                  dev run -v /var/run/docker.sock:/var/run/docker.sock docker.io/library/alpine:3
no "secret"                         dev run --secret id=x docker.io/library/alpine:3
no "runtime"                        dev run --runtime=/tmp/podman/evil docker.io/library/alpine:3
no "tls verify"                     dev run --tls-verify=false docker.io/library/alpine:3
no "signature policy"               dev run --signature-policy=/tmp/policy.json docker.io/library/alpine:3
no "pod subcommand"                 dev pod create --name p
no "system service"                 dev system service
no "non-allowlisted registry"       dev pull evil.example.com/library/x:1
no "build with host mount"          dev build --volume "$TMP:/x" .

printf '%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
