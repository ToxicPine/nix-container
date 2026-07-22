{
  declaredUsers,
  localOverlayStore ? { },
  n2c,
  nixSupervisionPackages,
  pkgs,
  runtime ? { },
  system,
}:

let
  overlay = import ./overlay.nix { inherit pkgs; };
  imagePkgs = pkgs.extend overlay;
  inherit (pkgs) lib;
  inherit (lib) types mkOption;

  userType = types.submodule {
    options = {
      uid = mkOption { type = types.int; };
    };
    freeformType = types.attrsOf types.unspecified;
  };

  systemType = types.submodule {
    options = {
      imageName = mkOption { type = types.str; };
      packages = mkOption { type = types.listOf types.package; };
      exposedPorts = mkOption {
        type = types.listOf types.port;
        default = [ ];
      };
    };
  };

  runtimeType = types.submodule {
    options = {
      contents = mkOption {
        type = types.listOf types.package;
        default = [ ];
      };
      files = mkOption {
        type = types.attrsOf types.path;
        default = { };
      };
      trees = mkOption {
        type = types.attrsOf types.path;
        default = { };
      };
    };
  };

  localOverlayStoreType = types.submodule {
    options.enable = mkOption {
      type = types.bool;
      default = false;
    };
  };

  schemaModule = {
    options = {
      declaredUsers = mkOption { type = types.attrsOf userType; };
      localOverlayStore = mkOption {
        type = localOverlayStoreType;
        default = { };
      };
      runtime = mkOption {
        type = runtimeType;
        default = { };
      };
      system = mkOption { type = systemType; };
    };
  };

  evaluatedConfiguration = lib.evalModules {
    modules = [
      schemaModule
      {
        config = {
          inherit
            declaredUsers
            localOverlayStore
            runtime
            system
            ;
        };
      }
    ];
  };

  imageConfig = evaluatedConfiguration.config;

  assertAbsoluteKeys =
    label: attrs:
    let
      relativePaths = lib.filter (path: !(lib.hasPrefix "/" path)) (lib.attrNames attrs);
    in
    if relativePaths == [ ] then
      attrs
    else
      throw "lib/image.nix: ${label} keys must be absolute paths: ${lib.concatStringsSep ", " relativePaths}";

  validatedRuntimeFiles = assertAbsoluteKeys "runtime.files" imageConfig.runtime.files;
  validatedRuntimeTrees = assertAbsoluteKeys "runtime.trees" imageConfig.runtime.trees;

  mutableConfigPrefix = "/opt/app";
  factorySettingsPrefix = "/opt/defaults";
  nixBuildUserCount = 10;
  staticBootstrapBusybox = pkgs.pkgsStatic.busybox;
  staticBootstrapCoreutils = pkgs.pkgsStatic.coreutils;
  localOverlayStoreEnabled = imageConfig.localOverlayStore.enable;
  localOverlayStoreUrl = "local-overlay://?lower-store=%2Fhost%2F%3Fread-only%3Dtrue&check-mount=false";
  nixExperimentalFeatures = [
    "nix-command"
    "flakes"
  ]
  ++ lib.optionals localOverlayStoreEnabled [
    "local-overlay-store"
    "read-only-local-store"
  ];

  entrypoint = imagePkgs.callPackage ./pkgs/entrypoint {
    inherit localOverlayStoreEnabled;
  };

  users = lib.mapAttrsToList (name: user: {
    inherit name;
    inherit (user) uid;
  }) imageConfig.declaredUsers;

  supervision = import ./pkgs/supervision {
    inherit nixSupervisionPackages pkgs;
  };

  shadowMaintHooks = imagePkgs.callPackage ./pkgs/shadow-maint-hooks {
    inherit (supervision) stopUserTrees;
  };

  renderPasswdEntry =
    {
      name,
      uid,
      gid,
      gecos,
      home,
      shell,
      password ? "x",
    }:
    lib.concatStringsSep ":" [
      name
      password
      (toString uid)
      (toString gid)
      gecos
      home
      shell
    ];

  renderGroupEntry =
    {
      name,
      gid,
      members ? [ ],
      password ? "x",
    }:
    lib.concatStringsSep ":" [
      name
      password
      (toString gid)
      (lib.concatStringsSep "," members)
    ];

  renderShadowEntry =
    {
      name,
      password ? "!",
      ...
    }:
    lib.concatStringsSep ":" [
      name
      password
      "1"
      ""
      ""
      ""
      ""
      ""
      ""
    ];

  renderGshadowEntry =
    {
      name,
      administrators ? [ ],
      members ? [ ],
      password ? "!",
      ...
    }:
    lib.concatStringsSep ":" [
      name
      password
      (lib.concatStringsSep "," administrators)
      (lib.concatStringsSep "," members)
    ];

  writeAccountFile =
    name: renderEntry: entries:
    pkgs.writeText name (lib.concatMapStringsSep "\n" renderEntry entries + "\n");

  nixBuildUsers = lib.genList (
    index:
    let
      number = index + 1;
    in
    {
      name = "nixbld${toString number}";
      uid = 30000 + number;
      gid = 30000;
      gecos = "Nix build user ${toString number}";
      home = "/var/empty";
      shell = "/bin/false";
    }
  ) nixBuildUserCount;

  configuredPasswdEntries = map (user: {
    inherit (user) name uid;
    gid = user.uid;
    gecos = "";
    home = "/home/${user.name}";
    shell = "/bin/bash";
  }) users;

  builtInPasswdEntries = [
    {
      name = "root";
      uid = 0;
      gid = 0;
      gecos = "root";
      home = "/root";
      shell = "/bin/bash";
    }
    {
      name = "sshd";
      uid = 65533;
      gid = 65533;
      gecos = "sshd";
      home = "/var/empty";
      shell = "/bin/false";
    }
    {
      name = "nobody";
      uid = 65534;
      gid = 65534;
      gecos = "nobody";
      home = "/nonexistent";
      shell = "/bin/false";
    }
  ]
  ++ nixBuildUsers;

  configuredGroupEntries = map (user: {
    inherit (user) name;
    gid = user.uid;
  }) users;

  builtInGroupEntries = [
    {
      name = "root";
      gid = 0;
    }
    {
      name = "sshd";
      gid = 65533;
    }
    {
      name = "nixbld";
      gid = 30000;
      members = map (user: user.name) nixBuildUsers;
    }
    {
      name = "nobody";
      gid = 65534;
    }
  ];

  passwdFile = writeAccountFile "passwd" renderPasswdEntry (
    builtInPasswdEntries ++ configuredPasswdEntries
  );

  groupFile = writeAccountFile "group" renderGroupEntry (
    builtInGroupEntries ++ configuredGroupEntries
  );

  shadowFile = writeAccountFile "shadow" renderShadowEntry (
    builtInPasswdEntries ++ configuredPasswdEntries
  );

  gshadowFile = writeAccountFile "gshadow" renderGshadowEntry (
    builtInGroupEntries ++ configuredGroupEntries
  );

  installRuntimeFiles = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (destination: source: ''
      mkdir -p "$out${builtins.dirOf destination}"
      cp ${source} "$out${destination}"
    '') validatedRuntimeFiles
  );

  installRuntimeTrees = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (destination: source: ''
      mkdir -p "$out${destination}"
      cp -R ${source}/. "$out${destination}/"
    '') validatedRuntimeTrees
  );

  installTree =
    {
      source,
      destination,
      noClobber ? false,
    }:
    ''
      mkdir -p "$out${destination}"
      cp -R ${if noClobber then "-n " else ""}${source}/. "$out${destination}/"
      chmod -R u+w "$out${destination}"
      if test -d "$out${destination}/bin"; then
        chmod 0755 "$out${destination}/bin"
        find "$out${destination}/bin" -type f -exec chmod 0755 {} +
      fi
    '';

  staticCommandNames = lib.attrNames (
    lib.filterAttrs (_name: type: type == "regular" || type == "symlink") (builtins.readDir ./fs/bin)
  );

  linkStaticCommands = lib.concatMapStringsSep "\n" (name: ''
    ln -s ${mutableConfigPrefix}/bin/${name} "$out/usr/bin/${name}"
  '') staticCommandNames;

  maximumImageLayerCount = 125;
  coreRuntimeLayerCount = 1;
  rootFilesystemLayerCount = 1;
  homeManagerLayerBudget = maximumImageLayerCount - coreRuntimeLayerCount - rootFilesystemLayerCount;
  nixStorePrefix = "/nix-base";

  # These packages are exposed as root-filesystem links after /nix is seeded.
  # Before then, OCI invokes entrypoint through its relocated /nix-base path;
  # the script itself uses only the static tools under /opt/bootstrap.
  rootFilesystemPackages = [
    entrypoint
    pkgs.bashInteractive
    pkgs.coreutils
    pkgs.dockerTools.binSh
    pkgs.dockerTools.caCertificates
    pkgs.git
    pkgs.jq
    pkgs.nix
    imagePkgs.nss-altfiles
    imagePkgs.seed-user-hm
    imagePkgs.shadow
    imagePkgs.util-linuxMinimal
    shadowMaintHooks
  ]
  ++ supervision.packages
  ++ imageConfig.system.packages;

  coreRuntimeRoots = lib.unique rootFilesystemPackages;
  homeManagerRuntimeRoots = lib.unique imageConfig.runtime.contents;
  runtimeStoreRoots = lib.unique (coreRuntimeRoots ++ homeManagerRuntimeRoots);

  # The registration retains the real /nix/store identities. The entrypoint
  # loads it only after copying the relocated files onto the mounted store.
  runtimeClosureInfo = pkgs.closureInfo { rootPaths = runtimeStoreRoots; };

  coreRuntimeLayer = n2c.buildLayer {
    deps = coreRuntimeRoots;
    inherit nixStorePrefix;
    maxLayers = coreRuntimeLayerCount;
    metadata.created_by = "n2c: system-image core runtime";
  };

  # n2c keeps nested layers as distinct OCI layers. The nesting records their
  # order and lets the outer layer exclude store paths already in the core.
  runtimeStoreLayer =
    if homeManagerRuntimeRoots == [ ] then
      coreRuntimeLayer
    else
      n2c.buildLayer {
        deps = homeManagerRuntimeRoots;
        inherit nixStorePrefix;
        maxLayers = homeManagerLayerBudget;
        layers = [ coreRuntimeLayer ];
        metadata.created_by = "n2c: prebuilt Home Manager runtime";
      };

  rootEnvironment = pkgs.buildEnv {
    name = "system-image-root-environment";
    paths = rootFilesystemPackages;
    pathsToLink = [
      "/bin"
      "/etc"
      "/lib"
      "/libexec"
      "/share"
    ];
    ignoreCollisions = true;
  };

  rootFilesystem = pkgs.runCommand "system-image-root-filesystem" { } ''
    set -euo pipefail
    : "''${out:?out must be set by runCommand}"

    mkdir -p "$out"
    cp -a ${rootEnvironment}/. "$out/"
    chmod -R u+w "$out"

    mkdir -p "$out/opt/bootstrap/bin"
    cp ${staticBootstrapBusybox}/bin/busybox "$out/opt/bootstrap/bin/busybox"
    cp ${staticBootstrapCoreutils}/bin/cp "$out/opt/bootstrap/bin/cp"
    chmod 0755 "$out/opt/bootstrap/bin/busybox"
    chmod 0755 "$out/opt/bootstrap/bin/cp"

    mkdir -p "$out/etc/nixcfg" "$out/etc/nix" "$out/etc/s6-linux-init" "$out/run"
    (
      cd "$out"
      ${supervision.installInitTreeCommands}
      # Nix outputs cannot retain the generated shutdownd FIFO. The static
      # init wrapper recreates it before handing control to s6-linux-init.
      rm -f etc/s6-linux-init/current/run-image/service/s6-linux-init-shutdownd/fifo
    )
    cp ${passwdFile} "$out/etc/passwd"
    cp ${groupFile} "$out/etc/group"
    cp ${shadowFile} "$out/etc/shadow"
    cp ${gshadowFile} "$out/etc/gshadow"
    : > "$out/etc/subuid"
    : > "$out/etc/subgid"
    chmod 0644 "$out/etc/passwd" "$out/etc/group" "$out/etc/subuid" "$out/etc/subgid"
    chmod 0600 "$out/etc/shadow" "$out/etc/gshadow"
    ${installRuntimeFiles}
    ${installRuntimeTrees}
    cat > "$out/etc/nsswitch.conf" <<'EOF'
    passwd: altfiles
    group: altfiles
    shadow: altfiles
    gshadow: altfiles
    hosts: files dns
    EOF
    cat > "$out/etc/nix/nix.conf" <<'EOF'
    experimental-features = ${lib.concatStringsSep " " nixExperimentalFeatures}
    sandbox = false
    substituters = https://cache.nixos.org/
    EOF
    mkdir -p "$out/etc/default"
    cat > "$out/etc/default/useradd" <<'EOF'
    CREATE_MAIL_SPOOL=no
    EOF
    if test -L "$out/etc/login.defs"; then
      cp -L "$out/etc/login.defs" "$out/etc/login.defs.mutable"
      mv "$out/etc/login.defs.mutable" "$out/etc/login.defs"
    fi
    sed -i -E '/^[[:space:]]*MAIL_(CHECK_ENAB|DIR|FILE)[[:space:]]/d' "$out/etc/login.defs"
    mkdir -p "$out/nix-base/var/nix" "$out/usr/bin"
    cp ${runtimeClosureInfo}/registration "$out/nix-base/var/nix/db-base"
    ln -s ${pkgs.coreutils}/bin/env "$out/usr/bin/env"
    ${linkStaticCommands}

    ${installTree {
      source = ./fs;
      destination = mutableConfigPrefix;
    }}
    ${installTree {
      source = ../fs;
      destination = mutableConfigPrefix;
      noClobber = true;
    }}
    ${installTree {
      source = ./fs;
      destination = factorySettingsPrefix;
    }}
    ${installTree {
      source = ../fs;
      destination = factorySettingsPrefix;
      noClobber = true;
    }}

    chmod -R a-w "$out${factorySettingsPrefix}"

    mkdir -p "$out/data" "$out/root" "$out/tmp" "$out/var/empty"
    rm -rf "$out/home"
    ln -s /data/homes "$out/home"
    chmod 1777 "$out/tmp"
  '';

in
(n2c.buildImage {
  name = imageConfig.system.imageName;
  tag = "latest";
  inherit nixStorePrefix;

  layers = [ runtimeStoreLayer ];
  copyToRoot = rootFilesystem;
  maxLayers = rootFilesystemLayerCount;

  perms = [
    {
      path = rootFilesystem;
      regex = "${rootFilesystem}/tmp";
      mode = "1777";
    }
  ];

  config = {
    Entrypoint = [ "${nixStorePrefix}/store/${builtins.baseNameOf "${entrypoint}"}/bin/entrypoint" ];
    Env = [
      "PATH=/bin:/sbin:/usr/bin:/usr/sbin"
      "LD_LIBRARY_PATH=/lib"
      "NIX_PAGER=cat"
      "HOME=/root"
    ]
    ++ lib.optional localOverlayStoreEnabled "SYSTEM_IMAGE_NIX_DAEMON_STORE=${localOverlayStoreUrl}";
    ExposedPorts = lib.listToAttrs (
      map (port: lib.nameValuePair "${toString port}/tcp" { }) imageConfig.system.exposedPorts
    );
    Volumes = {
      "/data" = { };
      "/nix" = { };
    };
  };
})
// {
  inherit
    coreRuntimeLayer
    rootFilesystem
    runtimeStoreLayer
    ;
}
