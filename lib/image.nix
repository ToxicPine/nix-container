{
  localOverlayStore ? null,
  pkgs,
  initialSystem,
  sources,
}:

let
  n2c = import ../n2c { inherit pkgs; };
  overlay = import ./overlay.nix { inherit pkgs; };
  imagePkgs = pkgs.extend overlay;
  inherit (pkgs) lib;
  nixSupervisionPackages = pkgs.callPackages "${sources.nix-supervise}/pkgs" { };
  imageConfig = initialSystem.image;
  # Image files can refer to a file within a store object; layer dependencies
  # must carry the entire object, not just that file.
  storeRoot =
    path:
    "${builtins.storeDir}/${lib.head (lib.splitString "/" (lib.removePrefix "${builtins.storeDir}/" path))}";
  imageComponents = lib.mapAttrs (name: c: {
    inherit (c.image)
      order
      maxLayers
      files
      trees
      ;
    # A small reference carrier keeps each component's service closure visible
    # to n2c before the aggregate generation collects the complete tree.
    storePaths =
      c.packages
      ++ map storeRoot (
        c.image.storePaths ++ lib.attrValues c.image.files ++ lib.attrValues c.image.trees
      )
      ++ [
        (pkgs.writeText "${name}-runtime-references" (
          builtins.toJSON {
            inherit (c)
              services
              users
              ;
          }
        ))
      ];
  }) initialSystem.components;
  orderedComponentNames = lib.sort (
    a: b:
    if imageComponents.${a}.order == imageComponents.${b}.order then
      a < b
    else
      imageComponents.${a}.order < imageComponents.${b}.order
  ) (lib.attrNames imageComponents);
  checkedLocalOverlayStore =
    if
      builtins.elem localOverlayStore [
        null
        "filesystem"
        "socket"
      ]
    then
      localOverlayStore
    else
      throw "localOverlayStore must be null, filesystem or socket";

  mutableConfigPrefix = "/opt/app";
  factorySettingsPrefix = "/opt/defaults";
  # Per-user factory configurations belong to the Home Manager component.
  # Keep the HM link namespace, but do not bake user directories into the
  # generic template layer as well.
  imageTemplate = lib.cleanSourceWith {
    src = ../fs;
    filter = path: type: !(type == "directory" && builtins.dirOf path == toString ../fs/hm-user);
  };
  staticBootstrapBusybox = pkgs.pkgsStatic.busybox;
  staticBootstrapCoreutils = pkgs.pkgsStatic.coreutils;
  # Built from the unpatched package set: the account-data patches on
  # util-linux would otherwise cascade into a from-source Rust toolchain.
  staticNixStoreBootstrapDiff = pkgs.pkgsStatic.callPackage ./packages/nix-store-bootstrap-diff { };
  # Both lower-store contracts live at fixed paths under /lower-store: a
  # read-only host store rooted there, or a Nix daemon socket at
  # /lower-store/socket.
  localOverlayStoreUrl =
    if checkedLocalOverlayStore == "socket" then
      "local-overlay://?lower-store=unix%3A%2F%2F%2Flower-store%2Fsocket&check-mount=false"
    else if checkedLocalOverlayStore == "filesystem" then
      "local-overlay://?lower-store=%2Flower-store%2F%3Fread-only%3Dtrue&check-mount=false"
    else
      null;
  baseNixExperimentalFeatures = [
    "nix-command"
    "flakes"
  ];
  localOverlayStoreNixExperimentalFeatures =
    if checkedLocalOverlayStore == "socket" then
      [ "local-overlay-store" ]
    else if checkedLocalOverlayStore == "filesystem" then
      [
        "local-overlay-store"
        "read-only-local-store"
      ]
    else
      [ ];
  nixExperimentalFeatures = baseNixExperimentalFeatures ++ localOverlayStoreNixExperimentalFeatures;

  entrypoint = imagePkgs.callPackage ./packages/entrypoint {
    inherit reconcileAccounts baselineAccounts;
    localOverlayStore = checkedLocalOverlayStore;
  };

  supervision = import ./packages/supervision {
    inherit nixSupervisionPackages pkgs;
  };

  shadowMaintHooks = imagePkgs.callPackage ./packages/shadow-maint-hooks { };

  # The system's factory generation, applied on a fresh /nix volume before
  # root has ever run refresh-system. Declared users, their seeding, and root
  # services all come from it. Baseline system accounts are created earlier
  # by the entrypoint using the same account application program.
  factorySystemGeneration = initialSystem.generation;

  baselineAccounts = import ./fs/nix-base/baseline-accounts.nix { inherit lib; };
  reconcileAccounts = import ./fs/nix-base/reconcile-accounts.nix { inherit pkgs; };

  componentFilesystems = lib.mapAttrs (
    name: component:
    let
      paths = lib.attrNames component.files ++ lib.attrNames component.trees;
      overlaps =
        lib.length (lib.unique paths) != lib.length paths
        || lib.any (a: lib.any (b: a != b && lib.hasPrefix "${a}/" b) paths) paths;
    in
    assert lib.assertMsg (
      !overlaps
    ) "component ${name}: image files/trees have overlapping destinations";
    pkgs.runCommand "system-image-${name}-files" { } (
      ''
        mkdir -p "$out"
      ''
      + lib.concatStringsSep "\n" (
        lib.mapAttrsToList (destination: source: ''
          destination="$out"${lib.escapeShellArg destination}
          mkdir -p "$(dirname "$destination")"
          cp ${lib.escapeShellArg source} "$destination"
        '') component.files
      )
      + lib.concatStringsSep "\n" (
        lib.mapAttrsToList (destination: source: ''
          destination="$out"${lib.escapeShellArg destination}
          mkdir -p "$destination"
          cp -R ${lib.escapeShellArg source}/. "$destination/"
        '') component.trees
      )
      + ''
        if test -d "$out/opt/defaults"; then chmod -R a-w "$out/opt/defaults"; fi
      ''
    )
  ) imageComponents;

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
  componentLayerBudget = lib.foldl' (sum: c: sum + c.maxLayers) 0 (lib.attrValues imageComponents);
  checkLayerBudget = lib.assertMsg (
    supervisionLayerCount + coreRuntimeLayerCount + componentLayerBudget + rootFilesystemLayerCount
    <= maximumImageLayerCount
  ) "system image: component layer budgets exceed ${toString maximumImageLayerCount} layers";
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
    imagePkgs.provision-user-home
    imagePkgs.shadow
    imagePkgs.util-linuxMinimal
    shadowMaintHooks
  ]
  ++ supervision.packages;

  # The s6 stack and nix-supervise tools change only with their pins, so they
  # get a layer of their own beneath the core runtime.
  supervisionRoots = lib.unique supervision.packages;
  coreRuntimeRoots = lib.unique (rootFilesystemPackages ++ [ pkgs.python3 ]);
  # Each layer explicitly excludes every earlier layer, as documented by n2c.
  # Keep the aggregate generation out of these component closures.
  layerState = (import ./build-oci-layers.nix { inherit lib n2c; }) (
    [
      {
        name = "supervision";
        deps = supervisionRoots;
        inherit nixStorePrefix;
        maxLayers = supervisionLayerCount;
        metadata.created_by = "n2c: system-image supervision";
      }
      {
        name = "core";
        deps = coreRuntimeRoots;
        inherit nixStorePrefix;
        maxLayers = coreRuntimeLayerCount;
        metadata.created_by = "n2c: system-image core runtime";
      }
    ]
    ++ map (name: {
      name = "component-${name}";
      deps = imageComponents.${name}.storePaths;
      copyToRoot = componentFilesystems.${name};
      inherit nixStorePrefix;
      maxLayers = imageComponents.${name}.maxLayers;
      metadata.created_by = "n2c: system component ${name}";
    }) orderedComponentNames
  );
  supervisionLayer = layerState.byName.supervision;
  coreRuntimeLayer = layerState.byName.core;
  componentLayers = lib.genAttrs orderedComponentNames (name: layerState.byName."component-${name}");
  runtimeStoreLayer = lib.last layerState.layers;

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

  baseRootFilesystem = pkgs.runCommand "system-image-root-filesystem" { } ''
    set -euo pipefail
    : "''${out:?out must be set by runCommand}"

    mkdir -p "$out"
    cp -a ${rootEnvironment}/. "$out/"
    chmod -R u+w "$out"

    # Real directories let component image layers contribute additional hooks
    # alongside the backend's generic home hook.
    rm -rf "$out/etc/shadow-maint"
    mkdir -p "$out/etc/shadow-maint"
    cp -R ${shadowMaintHooks}/etc/shadow-maint/. "$out/etc/shadow-maint/"

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
    # Bootstrap fills these through Shadow after the store is available.
    for account_file in passwd group shadow gshadow; do
      : > "$out/etc/$account_file"
    done
    : > "$out/etc/subuid"
    : > "$out/etc/subgid"
    chmod 0644 "$out/etc/passwd" "$out/etc/group" "$out/etc/subuid" "$out/etc/subgid"
    chmod 0600 "$out/etc/shadow" "$out/etc/gshadow"
    mkdir -p "$out${factorySettingsPrefix}"
    ln -s ${factorySystemGeneration} "$out${factorySettingsPrefix}/system-generation"
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
    mkdir -p "$out/usr/bin"
    ln -s ${pkgs.coreutils}/bin/env "$out/usr/bin/env"
    ${linkStaticCommands}

    ${installTree {
      source = ./fs;
      destination = mutableConfigPrefix;
    }}
    ${installTree {
      source = imageTemplate;
      destination = mutableConfigPrefix;
      noClobber = true;
    }}
    ${installTree {
      source = ./fs;
      destination = factorySettingsPrefix;
    }}
    ${installTree {
      source = imageTemplate;
      destination = factorySettingsPrefix;
      noClobber = true;
    }}

    chmod -R a-w "$out${factorySettingsPrefix}"

    mkdir -p "$out/data" "$out/root" "$out/tmp" "$out/var/empty"
    rm -rf "$out/home"
    ln -s /data/homes "$out/home"
    chmod 1777 "$out/tmp"
  '';

  # Export n2c's closure registration before adding boot metadata. Select the
  # actual image inventory so copyToRoot wrappers are not registered as store
  # objects. This produces text directly, without an intermediate database.
  contentImage = n2c.buildImage imageArgs;
  imageRegistration = import ./export-nix-store-registration.nix {
    inherit pkgs nixStorePrefix;
    image = contentImage;
  };

  # The final image uses the same content and layer definitions, with exported
  # registration added to the last filesystem fragment. No extra OCI layer or
  # SQLite database is needed, and metadata cannot depend on its own image.
  rootFilesystem = pkgs.runCommand "system-image-final-root-filesystem" { } ''
    cp -a ${baseRootFilesystem} "$out"
    chmod u+w "$out"
    mkdir -p "$out/nix-base/var/nix"
    cp ${imageRegistration}/registration "$out/nix-base/var/nix/db-base"
    cp ${imageRegistration}/store-paths "$out/nix-base/var/nix/store-paths"
  '';

  imageArgs = {
    name = imageConfig.name;
    tag = "latest";
    inherit nixStorePrefix;

    layers = layerState.layers;
    copyToRoot = baseRootFilesystem;
    maxLayers = rootFilesystemLayerCount;

    perms = [
      {
        path = baseRootFilesystem;
        regex = "${baseRootFilesystem}/tmp";
        mode = "1777";
      }
    ];

    config = {
      User = "0:0";
      Entrypoint = [ "${nixStorePrefix}/store/${builtins.baseNameOf "${entrypoint}"}/bin/entrypoint" ];
      Env = [
        "PATH=/run/current-system/sw/bin:/bin:/sbin:/usr/bin:/usr/sbin"
        "LD_LIBRARY_PATH=/lib"
        "NIX_PAGER=cat"
        "HOME=/root"
      ]
      ++ lib.optional (
        localOverlayStoreUrl != null
      ) "SYSTEM_IMAGE_NIX_DAEMON_STORE=${localOverlayStoreUrl}";
      ExposedPorts = lib.listToAttrs (
        map (port: lib.nameValuePair "${toString port}/tcp" { }) imageConfig.exposedPorts
      );
      Volumes = {
        "/data" = { };
        "/nix" = { };
      };
    };
  };
in
assert checkLayerBudget;
(n2c.buildImage (
  imageArgs
  // {
    copyToRoot = rootFilesystem;
    perms = [
      {
        path = rootFilesystem;
        regex = "${rootFilesystem}/tmp";
        mode = "1777";
      }
    ];
  }
))
// {
  inherit
    componentLayers
    componentFilesystems
    imageRegistration
    factorySystemGeneration
    coreRuntimeLayer
    rootFilesystem
    runtimeStoreLayer
    supervisionLayer
    ;
}
