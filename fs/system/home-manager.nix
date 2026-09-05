# Home Manager for declared users, as a module the system configuration
# imports, kept beside it under fs/ so it can be edited or replaced. A user
# with homeManager.enable gets ~/.nixcfg seeded while empty, a supervision
# tree of their own, and activation of their Home Manager generation on boot.
# Declared users with a factory configuration under fs/hm-user can have their
# generations prebuilt into the image.
{
  config,
  lib,
  pkgs,
  sources,
  ...
}:

let
  inherit (lib) mkOption types;
  nixSupervise = sources.nix-supervise;
  nixSupervisePackages = pkgs.callPackages "${nixSupervise}/pkgs" { };
  hostAdapterLibrary = import "${nixSupervise}/lib/host-adapter.nix" { inherit lib pkgs; };
  factoryConfigDir = ../hm-user;
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

  managedUsers = lib.filterAttrs (_: user: user.homeManager.enable) config.users;

  # Prebuilt activation packages for declared users with a factory
  # configuration. Nothing at runtime forces these.
  factoryGenerations = lib.optionalAttrs config.homeManager.buildProfiles (
    lib.mapAttrs
      (
        name: _:
        ((import sources.home-manager { inherit pkgs; }).lib.homeManagerConfiguration {
          inherit pkgs;
          modules = [
            (factoryConfigDir + "/${name}/home.nix")
            {
              home.username = name;
              home.homeDirectory = "/home/${name}";
            }
          ];
        }).activationPackage
      )
      (
        lib.filterAttrs (name: _: builtins.pathExists (factoryConfigDir + "/${name}/home.nix")) managedUsers
      )
  );

  # Each user's tree and activation are one host-adapter tree rendered into
  # the root tree: a longrun for the upstream runner and a oneshot that runs
  # the activation as the user once the tree is ready.
  userServices =
    name: user:
    let
      homeService = "home-${name}";
      userHome = "/home/${name}";
      rendered = hostAdapterLibrary.renderS6Services {
        treeName = name;
        treeRunner = nixSupervisePackages.treeRunner;
        tree = {
          owner = name;
          runtime = {
            kind = "user";
            location = config.supervision.userRuntimeRoot;
          };
          applyCommand = [
            "${activateUser}/bin/system-image-activate-user"
            name
            (boolArg user.homeManager.rebuildOnBoot)
            (boolArg user.homeManager.activateOnBoot)
          ];
          applyEnvironment = {
            HOME = userHome;
            USER = name;
            PATH = "${userHome}/.nix-profile/bin:${userHome}/.local/state/nix/profiles/home-manager/home-path/bin:/bin:/usr/bin";
          };
          applyTriggers = [ ];
          shutdownTimeoutMs = 30000;
          startTimeoutMs = 30000;
        };
        treeDependencies.${homeService} = { };
        applyDependencies.nix-daemon = { };
        # A rebuild on boot can take minutes.
        applyTimeoutMs = 0;
      };
    in
    {
      ${homeService} = {
        # The same program the useradd hook runs, plus the factory seed.
        process.argv = [
          "/bin/provision-user-home"
          name
          "/opt/defaults/hm-user/${name}"
        ];
        s6 = {
          type = "oneshot";
          # The base ensures the account first (see users.nix).
          dependencies."account-${name}" = { };
        };
      };
    }
    // rendered.services;
in
{
  options = {
    homeManager = {
      rebuildOnBoot = mkOption {
        type = types.bool;
        default = true;
        description = "Default for users: rebuild and activate ~/.nixcfg on every boot.";
      };

      activateOnBoot = mkOption {
        type = types.bool;
        default = true;
        description = "Default for users: when not rebuilding, activate the existing or factory generation on boot.";
      };

      buildProfiles = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Prebuild the Home Manager generation of every declared user that has
          a factory configuration into the image, so first boot activates it
          without building. Users added later are built on first activation.
        '';
      };
    };

    users = mkOption {
      type = types.attrsOf (
        types.submodule {
          options.homeManager = {
            enable = mkOption {
              type = types.bool;
              default = false;
              description = ''
                Seed ~/.nixcfg from /opt/defaults/hm-user/<name> (or the
                skeleton) while it is empty, run a supervision tree for this
                user, and activate their Home Manager generation.
              '';
            };

            rebuildOnBoot = mkOption {
              type = types.bool;
              default = config.homeManager.rebuildOnBoot;
              description = "Rebuild and activate ~/.nixcfg on every boot.";
            };

            activateOnBoot = mkOption {
              type = types.bool;
              default = config.homeManager.activateOnBoot;
              description = "When not rebuilding, activate the existing or factory generation on boot.";
            };
          };
        }
      );
    };
  };

  config = {
    supervision.system.services = lib.concatMapAttrs userServices managedUsers;

    # Prebuilt generations are factory defaults: the image carries their
    # closures and installs them where activation looks for them.
    factory = {
      contents = lib.attrValues factoryGenerations;
      trees = lib.optionalAttrs (factoryGenerations != { }) {
        "/opt/defaults/home-manager-generations" = pkgs.linkFarm "home-manager-factory-generations" (
          lib.mapAttrsToList (name: path: { inherit name path; }) factoryGenerations
        );
      };
    };
  };
}
