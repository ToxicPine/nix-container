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
        config.supervision.system = {
          tree.runtimeDirectory = "/run/nix-supervise/system";
          stateDirectory = "/data/system/supervision";
          producer = "system-image";
          services = declaredServices;
        };
      }
    ];
  };
  cfg = evaluated.config.supervision.system;
  # Record execution identities alongside the supervisor's service metadata.
  # Reconciliation uses the currently applied manifest to stop services before
  # removing their users or groups, including services nested in namespaces.
  serviceAccounts =
    services:
    lib.concatMapAttrs (
      _: service:
      lib.optionalAttrs (service.process.argv != [ ]) {
        ${service.s6.runtimeName} = {
          inherit (service.s6.execution) user group;
        };
      }
      // serviceAccounts service.services
    ) services;
  executionAccounts = pkgs.writeText "system-service-accounts.json" (
    builtins.toJSON (serviceAccounts cfg.services)
  );
  serviceBundle = pkgs.runCommand "system-service-bundle" { nativeBuildInputs = [ pkgs.jq ]; } ''
    mkdir -p "$out"
    cp -a ${cfg.serviceBundle}/. "$out/"
    chmod u+w "$out/manifest.json"
    # Keep the selected package environment in the applied bundle's GC root.
    jq --slurpfile accounts ${executionAccounts} --arg resources ${resources} \
      '.systemResources = $resources | .services |= with_entries(.value.execution = $accounts[0][.key])' \
      ${cfg.serviceBundle}/manifest.json > "$out/manifest.json"
  '';
  supervisionPackages = pkgs.callPackages "${sources.nix-supervise}/pkgs" { };
  apply = pkgs.writeShellApplication {
    name = "system-image-apply";
    runtimeInputs = [
      supervisionPackages.s6
      supervisionPackages.applyProgram
    ];
    text = ''
      # Serialize reconciliation and service activation together. The service
      # apply command uses the same lock, so tell it this process holds it.
      if [[ "''${SYSTEM_IMAGE_APPLY_LOCKED:-}" != 1 ]]; then
        exec s6-setlock -w /run/nix-supervise/system/apply.lock \
          env SYSTEM_IMAGE_APPLY_LOCKED=1 "$0" "$@"
      fi
      ${accounts.reconcileAccounts}/bin/system-reconcile-accounts ${resources}
      exec env NIX_SUPERVISE_APPLY_LOCKED=1 nix-supervise-apply \
        ${serviceBundle} /run/nix-supervise/system /data/system/supervision
    '';
  };
  generation = pkgs.runCommand "system-image-generation" { } ''
    mkdir -p "$out/bin"
    ln -s ${apply}/bin/system-image-apply "$out/bin/apply"
    ln -s ${serviceBundle} "$out/service-bundle"
    ln -s ${resources} "$out/resources"
    ln -s ${sw} "$out/sw"
  '';
in
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
  inherit (evaluated) config;
  image = schema.image composed.image;
}
