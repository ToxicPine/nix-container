# Runtime Home Manager component: account declarations and user supervision.
# OCI hooks and prebuilt profiles belong to lib/overlays/home-manager.
{
  pkgs,
  lib,
  sources,
  userRuntimeRoot,
  users ? { },
  rebuildOnBoot ? true,
  activateOnBoot ? true,
}:
let
  nixSupervise = sources.nix-supervise;
  nixSupervisePackages = pkgs.callPackages "${nixSupervise}/pkgs" { };
  hostAdapterLibrary = import "${nixSupervise}/lib/host-adapter.nix" { inherit lib pkgs; };
  boolArg = value: if value then "true" else "false";
  activateUser = pkgs.writeShellApplication {
    name = "system-image-activate-user";
    runtimeInputs = [
      pkgs.coreutils
      nixSupervisePackages.s6
      nixSupervisePackages.treeRunner
    ];
    text = builtins.readFile ./scripts/activate-user.sh;
  };
  userServices =
    name: user:
    let
      userHome = "/home/${name}";
      rendered = hostAdapterLibrary.renderS6Services {
        treeName = name;
        inherit (nixSupervisePackages) treeRunner;
        tree = {
          owner = name;
          runtime = {
            kind = "user";
            location = userRuntimeRoot;
          };
          applyCommand = [
            "${activateUser}/bin/system-image-activate-user"
            name
            (boolArg (user.rebuildOnBoot or rebuildOnBoot))
            (boolArg (user.activateOnBoot or activateOnBoot))
          ];
          applyEnvironment = {
            HOME = userHome;
            USER = name;
            PATH = "${userHome}/.nix-profile/bin:${userHome}/.local/state/nix/profiles/home-manager/home-path/bin:/run/current-system/sw/bin:/bin:/usr/bin";
          };
          applyTriggers = [ ];
          shutdownTimeoutMs = 30000;
          startTimeoutMs = 30000;
        };
        applyDependencies.nix-daemon = { };
        applyTimeoutMs = 0;
      };
    in
    rendered.services;
in
{
  users = lib.mapAttrs (
    _: user:
    builtins.removeAttrs user [
      "rebuildOnBoot"
      "activateOnBoot"
    ]
  ) users;
  services = lib.concatMapAttrs userServices users;
}
