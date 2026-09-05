{
  system ? "x86_64-linux",
  sources ? import ../fs/hm-base/npins,
}:

let
  pkgs = import sources.nixpkgs {
    localSystem.system = system;
    config.allowUnfree = true;
    overlays = [ (import ../fs/overlay.nix) ];
  };
  n2c = import ../n2c { inherit pkgs; };
in
import ../lib/image.nix {
  inherit n2c pkgs sources;
  image = import ./image.nix { inherit pkgs; };
  # The root supervision tree, declared in fs/system/system.nix. This
  # evaluation yields the image's factory generation and whatever factory
  # defaults the configuration asks the image to carry; refresh-system
  # re-evaluates the same file at runtime.
  rootTree = import ../lib/fs/system-base {
    inherit pkgs sources;
    modules = [ ../fs/system/system.nix ];
  };
}
