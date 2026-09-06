# Validate at the boundary, after overlays have produced their final values.
# Image fields stay lazy: refreshing the system never evaluates factory profiles.
{ lib }:
let
  check =
    condition: message: value:
    if condition then value else throw "system composition: ${message}";
  keys =
    label: allowed: value:
    check (builtins.isAttrs value) "${label} must be an attribute set" (
      check (lib.subtractLists allowed (builtins.attrNames value) == [ ])
        "${label}: unknown fields ${lib.concatStringsSep ", " (lib.subtractLists allowed (builtins.attrNames value))}"
        value
    );
  nameOK = name: builtins.isString name && builtins.match "[A-Za-z0-9_][A-Za-z0-9_-]*" name != null;
  pathOK =
    path:
    lib.hasPrefix "/" path
    && path != "/"
    && lib.all (
      part:
      !(builtins.elem part [
        ""
        "."
        ".."
      ])
    ) (lib.tail (lib.splitString "/" path));
  sourcePath =
    source:
    let
      path = if builtins.isPath source then "${source}" else toString source;
    in
    check (lib.hasPrefix "${builtins.storeDir}/" path)
      "image sources must be Nix paths, derivations or store paths"
      path;
  paths =
    label: value:
    check (builtins.isAttrs value) "${label} must be an attribute set" (
      lib.mapAttrs (
        path: source:
        check (pathOK path && lib.types.path.check source)
          "${label}.${path}: expected a normalized absolute destination and a source path"
          (sourcePath source)
      ) value
    );
  packages =
    label: value:
    check (
      builtins.isList value && lib.all lib.isDerivation value
    ) "${label} must be a list of packages" value;
  storePaths =
    label: value:
    check (
      builtins.isList value && lib.all lib.types.path.check value
    ) "${label} must be a list of store sources" (map sourcePath value);
  idOK = id: builtins.isInt id && id > 0 && id < 4294967295;
  textOK = text: builtins.isString text && builtins.match ".*[:\n\r].*" text == null;
  users =
    value:
    lib.mapAttrs (
      name: raw:
      let
        u = keys "users.${name}" [ "uid" "gid" "shell" "description" "extraGroups" ] raw;
      in
      check (nameOK name && idOK (u.uid or null) && idOK (u.gid or u.uid))
        "users.${name}: expected a valid name and positive uid/gid"
        (
          check
            (
              textOK (u.shell or "/bin/bash")
              && lib.hasPrefix "/" (u.shell or "/bin/bash")
              && textOK (u.description or "")
              && builtins.isList (u.extraGroups or [ ])
              && lib.all nameOK (u.extraGroups or [ ])
            )
            "users.${name}: invalid shell, description or supplementary groups"
            {
              inherit (u) uid;
              gid = u.gid or u.uid;
              shell = u.shell or "/bin/bash";
              description = u.description or "";
              extraGroups = u.extraGroups or [ ];
              home = "/home/${name}";
            }
        )
    ) value;
  groups =
    value:
    lib.mapAttrs (
      name: raw:
      let
        g = keys "groups.${name}" [ "gid" "members" ] raw;
      in
      check
        (
          nameOK name
          && idOK (g.gid or null)
          && builtins.isList (g.members or [ ])
          && lib.all nameOK (g.members or [ ])
        )
        "groups.${name}: expected a valid name, positive gid and member names"
        {
          inherit (g) gid;
          members = g.members or [ ];
        }
    ) value;
in
{
  inherit check;
  composition = keys "system" [
    "pkgs"
    "sources"
    "lib"
    "infuse"
    "callComponent"
    "components"
    "image"
  ];
  image =
    raw:
    let
      i = keys "image" [ "name" "exposedPorts" ] raw;
    in
    {
      name = check (builtins.isString i.name && i.name != "") "image.name must be nonempty" i.name;
      exposedPorts = check (
        builtins.isList i.exposedPorts
        && lib.all (port: builtins.isInt port && port > 0 && port < 65536) i.exposedPorts
      ) "image.exposedPorts must contain TCP port numbers" i.exposedPorts;
    };
  accounts =
    { users, groups }:
    check (lib.all (u: lib.all (g: builtins.hasAttr g groups) u.extraGroups) (lib.attrValues users))
      "every supplementary group must be declared"
      (
        check
          (
            lib.length (lib.unique (map (u: u.uid) (lib.attrValues users))) == lib.length (lib.attrNames users)
            &&
              lib.length (lib.unique (map (g: g.gid) (lib.attrValues groups)))
              == lib.length (lib.attrNames groups)
          )
          "declared UIDs and GIDs must be unique"
          (builtins.deepSeq { inherit users groups; } { inherit users groups; })
      );
  component =
    name: raw:
    let
      c = keys "components.${name}" [
        "enable"
        "packages"
        "users"
        "groups"
        "services"
        "image"
        "override"
        "overrideDerivation"
      ] raw;
      image = keys "components.${name}.image" [ "order" "maxLayers" "storePaths" "files" "trees" ] (
        c.image or { }
      );
    in
    check (nameOK name) "invalid component name ${name}" {
      enable = check (builtins.isBool (c.enable or true)) "components.${name}.enable must be boolean" (
        c.enable or true
      );
      packages = packages "components.${name}.packages" (c.packages or [ ]);
      users = users (c.users or { });
      groups = groups (c.groups or { });
      services = c.services or { };
      image = {
        order = check (builtins.isInt (image.order or 100)) "image.order must be an integer" (
          image.order or 100
        );
        maxLayers = check (
          builtins.isInt (image.maxLayers or 1) && (image.maxLayers or 1) > 0
        ) "image.maxLayers must be positive" (image.maxLayers or 1);
        storePaths = storePaths "components.${name}.image.storePaths" (image.storePaths or [ ]);
        files = paths "components.${name}.image.files" (image.files or { });
        trees = paths "components.${name}.image.trees" (image.trees or { });
      };
    };
}
