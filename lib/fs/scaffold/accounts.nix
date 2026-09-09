# Prepare the account manifest and reconciliation command. Shadow performs
# the actual mutations; this layer adds private groups and checks consistency.
{
  pkgs,
  schema,
  users,
  explicitGroups,
  sw,
}:
let
  inherit (pkgs) lib;
  inherit (schema) check;
  baseline = import ./baseline-accounts.nix { inherit lib; };
  groups = lib.foldl' (
    result: name:
    let
      user = users.${name};
    in
    check (!(result ? ${name}) || result.${name}.gid == user.gid)
      "private group ${name} disagrees with users.${name}.gid"
      (
        result
        // {
          ${name} =
            result.${name} or {
              inherit (user) gid;
              members = [ ];
            };
        }
      )
  ) explicitGroups (lib.attrNames users);
  resourcesManifest = pkgs.writeText "system-resources.json" (
    builtins.toJSON {
      inherit baseline;
      inherit
        users
        groups
        ;
    }
  );
  resources = pkgs.linkFarm "system-resources" [
    {
      name = "sw";
      path = sw;
    }
    {
      name = "manifest.json";
      path = resourcesManifest;
    }
  ];
  reconcileAccounts = import ./reconcile-accounts.nix { inherit pkgs; };
in
assert check (
  lib.intersectLists (lib.attrNames users) (lib.attrNames baseline.users) == [ ]
) "built-in users belong to the container backend" true;
assert check (
  lib.intersectLists (lib.attrNames groups) (lib.attrNames baseline.groups) == [ ]
) "built-in groups belong to the container backend" true;
assert builtins.seq (schema.accounts {
  users = baseline.users // users;
  groups = baseline.groups // groups;
}) true;
{
  inherit
    users
    groups
    resources
    reconcileAccounts
    ;
}
