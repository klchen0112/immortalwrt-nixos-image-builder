## Recipes for building OpenWrt images

# Number of parallel build jobs (auto-detected CPU count)
nproc := shell("nproc")

## Build the Cudy TR3000 image with parallel builds + cachix
build-cudy:
	nix-fast-build -f .#packages.x86_64-linux.cudy-tr3000 -j $(nproc) --cachix-cache klchen0112

## Build the Cudy TR3000 image without cachix
build-cudy-nocache:
	nix-fast-build -f .#packages.x86_64-linux.cudy-tr3000 -j $(nproc)

## Regular single-threaded build
nix-build-cudy:
	nix build .#cudy-tr3000 --no-link
