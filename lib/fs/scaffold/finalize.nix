# Assemble validated components into the runtime supervision generation.
# Image rendering consumes their normalized declarations separately.
{
  pkgs,
  sources,
  composed,
}:
let
  inherit (pkgs) lib;
  schema = import ./schema.nix { inherit lib; };
  inherit (schema) check;
  components = lib.filterAttrs (_: component: component.enable) (
    lib.mapAttrs schema.component composed.components
  );
  # Each name has one component owner. Change that component explicitly
  # instead of letting merge order choose between conflicting declarations.
  collect =
    field:
    lib.foldl' (
      result: name:
      let
        contribution = components.${name}.${field};
        duplicates = lib.intersectLists (lib.attrNames result) (lib.attrNames contribution);
      in
      check (duplicates == [ ])
        "${field}: component ${name} duplicates ${lib.concatStringsSep ", " duplicates}"
        (result // contribution)
    ) { } (lib.attrNames components);
  packages = lib.unique (lib.concatMap (c: c.packages) (lib.attrValues components));
  sw = pkgs.buildEnv {
    name = "system-environment";
    paths = packages;
    pathsToLink = [
      "/bin"
      "/lib"
      "/libexec"
      "/share"
    ];
    ignoreCollisions = false;
  };
  declaredServices = collect "services";
  # The base component's services need only the bootstrap identities created
  # by the entrypoint. They stay up across resource changes, so a refresh does
  # not restart the daemon that user activations are building through.
  prerequisiteServices = lib.attrNames (components.base.services or { });
  accounts = import ./accounts.nix {
    inherit pkgs schema sw;
    users = collect "users";
    explicitGroups = collect "groups";
  };
  inherit (accounts) users groups resources;
  evaluated = import "${sources.nix-supervise}/lib/eval-system-services.nix" {
    inherit pkgs;
    modules = [
      {
        supervision.system = {
          tree.runtimeDirectory = "/run/nix-supervise/system";
          stateDirectory = "/data/system/supervision";
          producer = "system-image";
          # Stop dependent services before account changes; start them only
          # after reconciliation succeeds and the package environment is set.
          services = {
            system-resources = accounts.service;
          }
          // lib.mapAttrs (
            name: service:
            if builtins.elem name prerequisiteServices then
              service
            else
              lib.recursiveUpdate service {
                s6.dependencies.system-resources = { };
              }
          ) declaredServices;
        };
      }
    ];
  };
  cfg = evaluated.config.supervision.system;
  generation = pkgs.runCommand "system-image-generation" { } ''
    mkdir -p "$out/bin"
    ln -s ${cfg.applyPackage}/bin/nix-supervise-system-apply-current "$out/bin/apply"
    ln -s ${cfg.serviceBundle} "$out/service-bundle"
    ln -s ${resources} "$out/resources"
    ln -s ${sw} "$out/sw"
  '';
in
assert check (
  !(declaredServices ? system-resources)
) "system-resources is reserved by the wrapper" true;
assert builtins.seq accounts true;
{
  inherit
    pkgs
    sources
    components
    generation
    resources
    packages
    users
    groups
    ;
  config = evaluated.config;
  image = schema.image composed.image;
}
