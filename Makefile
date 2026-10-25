ARCH ?= x86_64-linux
VAR ?= compute
VARIANTS = dev compute storage
BASE = ostrium-linux-$(VAR)-$(ARCH)

.PHONY: check test format all clean verify sbom sign $(VARIANTS)

# Evaluate every output for both architectures. qcow2/raw builds run a KVM
# guest, so this stays evaluation-only; the image targets below do the builds.
check:
	nix flake check --no-build --all-systems -L

test:
	bash tests/policy.sh

format:
	nixfmt flake.nix modules/*.nix hosts/*.nix

all: $(VARIANTS)

# make dev | compute | storage  -> qcow2 + ISO for that variant
$(VARIANTS): %:
	nix build ".#packages.$(ARCH).$*-qcow2" -L --out-link result-$*-qcow2
	nix build ".#packages.$(ARCH).$*-iso" -L --out-link result-$*-iso
	@echo "built: $$(readlink -f result-$*-qcow2)"

# make qcow2-dev | iso-compute | raw-storage
qcow2-%:
	nix build ".#packages.$(ARCH).$*-qcow2" -L --out-link result-$*-qcow2

iso-%:
	nix build ".#packages.$(ARCH).$*-iso" -L --out-link result-$*-iso

raw-%:
	nix build ".#packages.$(ARCH).$*-raw" -L --out-link result-$*-raw

clean:
	rm -rf result result-* *.spdx.json *.cosign.bundle

sbom:
	nix shell --inputs-from . nixpkgs#syft -c syft scan dir:result-$(VAR)-qcow2 -o spdx-json > $(BASE).spdx.json

sign: sbom
	cosign sign-blob --yes --bundle $(BASE).cosign.bundle result-$(VAR)-qcow2/nixos.qcow2

# cosign.pub must be the public half of the key used for `make sign`.
verify:
	cosign verify-blob \
	  --key cosign.pub \
	  --bundle $(BASE).cosign.bundle \
	  result-$(VAR)-qcow2/nixos.qcow2
