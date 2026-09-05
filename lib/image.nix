{
  image,
  localOverlayStore ? null,
  n2c,
  pkgs,
  rootTree,
  sources,
}:

let
  overlay = import ./overlay.nix { inherit pkgs; };
  imagePkgs = pkgs.extend overlay;
  inherit (pkgs) lib;
  inherit (lib) types mkOption;
  nixSupervisionPackages = pkgs.callPackages "${sources.nix-supervise}/pkgs" { };

  imageType = types.submodule {
    options = {
      imageName = mkOption { type = types.str; };
      packages = mkOption { type = types.listOf types.package; };
      exposedPorts = mkOption {
        type = types.listOf types.port;
        default = [ ];
      };
    };
  };

  schemaModule = {
    options = {
      image = mkOption { type = imageType; };
      localOverlayStore = mkOption {
        type = types.nullOr (
          types.enum [
            "filesystem"
            "socket"
          ]
        );
        default = null;
      };
    };
  };

  evaluatedConfiguration = lib.evalModules {
    modules = [
      schemaModule
      {
        config = {
          inherit
            image
            localOverlayStore
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

  # Build-time interface between the root tree configuration and the image:
  # store paths to carry, and files and trees to install as factory defaults.
  factoryDefaults = rootTree.config.factory;
  validatedFactoryFiles = assertAbsoluteKeys "factory.files" factoryDefaults.files;
  validatedFactoryTrees = assertAbsoluteKeys "factory.trees" factoryDefaults.trees;

  mutableConfigPrefix = "/opt/app";
  factorySettingsPrefix = "/opt/defaults";
  nixBuildUserCount = 10;
  staticBootstrapBusybox = pkgs.pkgsStatic.busybox;
  staticBootstrapCoreutils = pkgs.pkgsStatic.coreutils;
  # Built from the unpatched package set: the account-data patches on
  # util-linux would otherwise cascade into a from-source Rust toolchain.
  staticNixStoreBootstrapDiff = pkgs.pkgsStatic.callPackage ./pkgs/nix-store-bootstrap-diff { };
  # Both lower-store contracts live at fixed paths under /lower-store: a
  # read-only host store rooted there, or a Nix daemon socket at
  # /lower-store/socket.
  localOverlayStoreUrl =
    if imageConfig.localOverlayStore == "socket" then
      "local-overlay://?lower-store=unix%3A%2F%2F%2Flower-store%2Fsocket&check-mount=false"
    else if imageConfig.localOverlayStore == "filesystem" then
      "local-overlay://?lower-store=%2Flower-store%2F%3Fread-only%3Dtrue&check-mount=false"
    else
      null;
  baseNixExperimentalFeatures = [
    "nix-command"
    "flakes"
  ];
  localOverlayStoreNixExperimentalFeatures =
    if imageConfig.localOverlayStore == "socket" then
      [ "local-overlay-store" ]
    else if imageConfig.localOverlayStore == "filesystem" then
      [
        "local-overlay-store"
        "read-only-local-store"
      ]
    else
      [ ];
  nixExperimentalFeatures = baseNixExperimentalFeatures ++ localOverlayStoreNixExperimentalFeatures;

  entrypoint = imagePkgs.callPackage ./pkgs/entrypoint {
    inherit (imageConfig) localOverlayStore;
  };

  supervision = import ./pkgs/supervision {
    inherit nixSupervisionPackages pkgs;
  };

  shadowMaintHooks = imagePkgs.callPackage ./pkgs/shadow-maint-hooks { };

  # The root tree's factory generation, applied on a fresh /nix volume before
  # root has ever run refresh-system. Declared users, their seeding, and root
  # services all come from it; the image's own account database holds only
  # system accounts.
  factorySystemGeneration = rootTree.config.supervision.system.generation;

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

  passwdFile = writeAccountFile "passwd" renderPasswdEntry builtInPasswdEntries;
  groupFile = writeAccountFile "group" renderGroupEntry builtInGroupEntries;
  shadowFile = writeAccountFile "shadow" renderShadowEntry builtInPasswdEntries;
  gshadowFile = writeAccountFile "gshadow" renderGshadowEntry builtInGroupEntries;

  installFactoryFiles = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (destination: source: ''
      mkdir -p "$out${builtins.dirOf destination}"
      cp ${source} "$out${destination}"
    '') validatedFactoryFiles
  );

  installFactoryTrees = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (destination: source: ''
      mkdir -p "$out${destination}"
      cp -R ${source}/. "$out${destination}/"
    '') validatedFactoryTrees
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
  supervisionLayerCount = 1;
  coreRuntimeLayerCount = 1;
  rootFilesystemLayerCount = 1;
  factoryLayerBudget =
    maximumImageLayerCount - supervisionLayerCount - coreRuntimeLayerCount - rootFilesystemLayerCount;
  nixStorePrefix = "/nix-base";

  # These packages are exposed as root-filesystem links after /nix is seeded.
  # Before then, OCI invokes entrypoint through its relocated /nix-base path;
  # the script itself uses only the static tools under /opt/bootstrap.
  rootFilesystemPackages = [
    entrypoint
    factorySystemGeneration
    pkgs.bashInteractive
    pkgs.coreutils
    pkgs.dockerTools.binSh
    pkgs.dockerTools.caCertificates
    pkgs.git
    pkgs.jq
    pkgs.nix
    imagePkgs.nss-altfiles
    imagePkgs.provision-user-home
    imagePkgs.shadow
    imagePkgs.util-linuxMinimal
    shadowMaintHooks
  ]
  ++ supervision.packages
  ++ imageConfig.image.packages;

  # The s6 stack and nix-supervise tools change only with their pins, so they
  # get a layer of their own beneath the core runtime.
  supervisionRoots = lib.unique supervision.packages;
  coreRuntimeRoots = lib.unique rootFilesystemPackages;
  factoryRoots = lib.unique factoryDefaults.contents;
  runtimeStoreRoots = lib.unique (supervisionRoots ++ coreRuntimeRoots ++ factoryRoots);

  # The registration retains the real /nix/store identities. The entrypoint
  # loads it only after copying the relocated files onto the mounted store.
  runtimeClosureInfo = pkgs.closureInfo { rootPaths = runtimeStoreRoots; };

  supervisionLayer = n2c.buildLayer {
    deps = supervisionRoots;
    inherit nixStorePrefix;
    maxLayers = supervisionLayerCount;
    metadata.created_by = "n2c: system-image supervision";
  };

  coreRuntimeLayer = n2c.buildLayer {
    deps = coreRuntimeRoots;
    inherit nixStorePrefix;
    maxLayers = coreRuntimeLayerCount;
    layers = [ supervisionLayer ];
    metadata.created_by = "n2c: system-image core runtime";
  };

  # n2c keeps nested layers as distinct OCI layers. The nesting records their
  # order and lets the outer layer exclude store paths already in the core.
  runtimeStoreLayer =
    if factoryRoots == [ ] then
      coreRuntimeLayer
    else
      n2c.buildLayer {
        deps = factoryRoots;
        inherit nixStorePrefix;
        maxLayers = factoryLayerBudget;
        layers = [ coreRuntimeLayer ];
        metadata.created_by = "n2c: system-image factory defaults";
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
    cp ${staticNixStoreBootstrapDiff}/bin/nix-store-bootstrap-diff \
      "$out/opt/bootstrap/bin/nix-store-bootstrap-diff"
    chmod 0755 "$out/opt/bootstrap/bin/"*

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
    ${installFactoryFiles}
    ${installFactoryTrees}
    mkdir -p "$out${factorySettingsPrefix}/system-generation"
    cp -R ${factorySystemGeneration}/. "$out${factorySettingsPrefix}/system-generation/"
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
    cp ${runtimeClosureInfo}/store-paths "$out/nix-base/var/nix/store-paths"
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
  name = imageConfig.image.imageName;
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
    ++ lib.optional (
      localOverlayStoreUrl != null
    ) "SYSTEM_IMAGE_NIX_DAEMON_STORE=${localOverlayStoreUrl}";
    ExposedPorts = lib.listToAttrs (
      map (port: lib.nameValuePair "${toString port}/tcp" { }) imageConfig.image.exposedPorts
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
    factorySystemGeneration
    supervisionLayer
    ;
}
