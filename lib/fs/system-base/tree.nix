# The root supervision tree of the container: nix-supervise's system-scope
# services, fixed to the paths s6-linux-init and the account hooks use, plus
# the two outputs the image consumes. `generation` is what the root profile
# points at and what stage 2 applies; `factory` is the build-time interface
# through which modules ask the image to carry and install defaults.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkOption types;
  cfg = config.supervision.system;
in
{
  options = {
    factory = {
      contents = mkOption {
        type = types.listOf types.package;
        default = [ ];
        description = "Store paths the image must carry for the factory generation to work.";
      };

      files = mkOption {
        type = types.attrsOf types.path;
        default = { };
        description = "Files installed into the image at absolute paths, as factory defaults.";
      };

      trees = mkOption {
        type = types.attrsOf types.path;
        default = { };
        description = "Directories installed into the image at absolute paths, as factory defaults.";
      };
    };

    supervision.system.generation = mkOption {
      type = types.package;
      readOnly = true;
      internal = true;
      description = "Selected-generation output containing bin/apply and the service bundle.";
    };
  };

  config.supervision.system = {
    # Fixed by the image: s6-linux-init starts the runner at the runtime
    # directory, and the account hooks address the live database below it.
    tree.runtimeDirectory = "/run/nix-supervise/system";
    stateDirectory = "/data/system/supervision";
    producer = "system-image";

    generation = pkgs.runCommand "system-image-supervision-generation" { } ''
      mkdir -p "$out/bin"
      ln -s ${cfg.applyPackage}/bin/nix-supervise-system-apply-current "$out/bin/apply"
      ln -s ${cfg.serviceBundle} "$out/service-bundle"
    '';
  };
}
