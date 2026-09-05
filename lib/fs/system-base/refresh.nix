# Runtime rebuild of the root supervision generation from the persistent
# system configuration linked at /opt/app/system. Paths are relative to the
# /opt/app layout, where this file lives beside the pins and the config.
{
  system ? builtins.currentSystem,
}:

let
  sources = import ../hm-base/npins;
  pkgs = import sources.nixpkgs {
    localSystem.system = system;
    config.allowUnfree = true;
    overlays = [ (import ../overlay.nix) ];
  };
in
(import ./default.nix {
  inherit pkgs sources;
  modules = [ ../system/system.nix ];
}).config.supervision.system.generation
