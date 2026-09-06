{
  system ? "x86_64-linux",
  sources ? import ../fs/hm-base/npins,
  overlays ? [
    ../fs/nix/system.nix
    (import ../lib/modules/home-manager { })
  ],
}:

let
  pkgs = import sources.nixpkgs {
    localSystem.system = system;
    config.allowUnfree = true;
    overlays = [ (import ../fs/overlay.nix) ];
  };
  # Ordered system overlays produce the factory generation and image defaults.
  # The template uses fs/nix/system.nix, also evaluated by runtime refresh.
  initialSystem = import ../lib/fs/nix-base {
    inherit pkgs sources overlays;
  };
in
import ../lib/image.nix {
  inherit initialSystem;
  inherit (initialSystem) pkgs sources;
}
