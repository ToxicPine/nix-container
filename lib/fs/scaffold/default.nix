# Compose a system first; rendering it must not erase component ownership.
# This directory is also installed with the rest of lib/fs at /opt/app for fs/bin/refresh-system.
{
  pkgs,
  sources,
  overlays ? [ ],
}:
let
  inherit (pkgs) lib;
  schema = import ./schema.nix { inherit lib; };
  infuse = (import ./vendor/infuse.nix { inherit lib; }).v1.infuse;
  scope = final: {
    inherit lib infuse;
    callComponent = lib.callPackageWith {
      inherit (final) pkgs sources;
      inherit lib;
      userRuntimeRoot = "/run/nix-supervise/users";
    };
  };
  initial =
    final:
    (scope final)
    // {
      inherit pkgs sources;
      components.base = final.callComponent ./base.nix { };
      image = {
        name = "system-image";
        exposedPorts = [ ];
      };
    };
  callOverlay =
    final: overlay:
    lib.callPackageWith {
      inherit (final) pkgs sources;
      inherit lib infuse;
    } overlay { };
  composed = lib.fix (
    final:
    let
      result = lib.foldl' (
        prev: overlay: prev // (callOverlay final overlay) final prev
      ) (initial final) overlays;
    in
    (scope final)
    // {
      # Check the complete overlay result outside the fixed point, before its
      # public fields are consumed. Otherwise unknown fields disappear here.
      valid = builtins.seq (schema.composition result) true;
      # Keep the scope's attribute names and helper functions independent of
      # overlays. Looking up final.infuse must not evaluate that same overlay.
      inherit (result)
        pkgs
        sources
        components
        image
        ;
    }
  );
in
assert composed.valid;
import ./finalize.nix {
  inherit (composed) pkgs sources;
  inherit composed;
}
