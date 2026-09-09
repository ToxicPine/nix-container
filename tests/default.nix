# nix-build tests --no-out-link
# Everything is a build. The VM test needs KVM; the rest runs in any sandbox.
let
  sources = import ../fs/hm-base/npins;
  pkgs = import sources.nixpkgs { };
in
{
  scaffold = pkgs.writeText "system-scaffold-tests" (builtins.toJSON (import ./scaffold.nix));
  boot = import ./boot.nix;
  home-manager = import ./home-manager.nix;
  layers = import ./layers.nix;
  image = import ./image.nix;
  vm = import ./vm.nix;
}
