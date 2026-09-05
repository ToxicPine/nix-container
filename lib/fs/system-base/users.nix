# Users as declarations. The base ensures each declared account exists
# through a oneshot named `account-<name>`; modules such as home-manager.nix
# extend a user with more options and services, and depend on that name.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkOption types;
  cfg = config;
  validServiceName = name: builtins.match "[A-Za-z0-9_][A-Za-z0-9_-]*" name != null;

  ensureAccount = pkgs.writeShellApplication {
    name = "system-image-ensure-account";
    runtimeInputs = [ pkgs.coreutils ];
    text = builtins.readFile ./scripts/ensure-account.sh;
  };
in
{
  options.users = mkOption {
    type = types.attrsOf (
      types.submodule {
        options.uid = mkOption {
          type = types.int;
          description = "Numeric user id, used when the account has to be created.";
        };
      }
    );
    default = { };
    description = "Users the root supervision tree provides accounts and services for.";
  };

  config = {
    assertions = lib.mapAttrsToList (name: _: {
      assertion = validServiceName name;
      message = "users.${name}: user names must match [A-Za-z0-9_][A-Za-z0-9_-]* to name s6-rc services";
    }) cfg.users;

    supervision.system.services = lib.mapAttrs' (
      name: user:
      lib.nameValuePair "account-${name}" {
        process.argv = [
          "${ensureAccount}/bin/system-image-ensure-account"
          name
          (toString user.uid)
        ];
        s6.type = "oneshot";
      }
    ) cfg.users;
  };
}
