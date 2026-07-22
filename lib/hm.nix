{
  pkgs,
  home-manager,
  declaredUsers,
  hmPolicy ? { },
  hmExtraSpecialArgs ? { },
}:

let
  inherit (pkgs) lib;
  inherit (lib) types mkOption;

  policyType = types.submodule {
    options = {
      buildProfiles = mkOption {
        type = types.bool;
        default = true;
        description = "Prebuild declared-user activation packages as Nix store seeds.";
      };
      activateOnBoot = mkOption {
        type = types.bool;
        default = true;
      };
      rebuildOnBoot = mkOption {
        type = types.bool;
        default = true;
      };
    };
  };

  schemaModule = {
    options.hmPolicy = mkOption {
      type = policyType;
      default = { };
    };
  };

  policy =
    (lib.evalModules {
      modules = [
        schemaModule
        { config.hmPolicy = hmPolicy; }
      ];
    }).config.hmPolicy;

  mkHome =
    name:
    home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      extraSpecialArgs = hmExtraSpecialArgs;
      modules = [
        ../fs/hm-user/${name}/home.nix
        {
          home.username = name;
          home.homeDirectory = "/home/${name}";
        }
      ];
    };

  declaredHmUsers = lib.filterAttrs (
    name: _: builtins.pathExists ../fs/hm-user/${name}/home.nix
  ) declaredUsers;

  homeConfig = lib.mapAttrs (name: _: mkHome name) declaredHmUsers;

  profileStoreSeeds =
    if policy.buildProfiles then lib.mapAttrs (_: hc: hc.activationPackage) homeConfig else { };
in

{
  runtime = {
    contents = lib.attrValues profileStoreSeeds;
    trees = { };

    files = {
      "/etc/home-manager-policy.json" = pkgs.writeText "home-manager-policy.json" (
        builtins.toJSON policy
      );
    };
  };
}
