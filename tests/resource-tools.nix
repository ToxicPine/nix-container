# Real container account tools and hooks for the isolated resource tests.
let
  sources = import ../fs/hm-base/npins;
  pkgs = import sources.nixpkgs { };
  imagePkgs = pkgs.extend (import ../lib/overlay.nix { inherit pkgs; });
  image = import ../nix {
    overlays = [
      ../fs/nix/system.nix
      (import ../lib/modules/home-manager { buildProfiles = false; })
    ];
  };
  commands = pkgs.buildEnv {
    name = "resource-test-commands";
    paths = [
      imagePkgs.shadow
      imagePkgs.provision-user-home
      pkgs.bash
      pkgs.coreutils
      pkgs.gawk
      pkgs.nix
    ];
    pathsToLink = [ "/bin" ];
  };
in
pkgs.linkFarm "resource-test-tools" [
  {
    name = "commands";
    path = commands;
  }
  {
    name = "hooks";
    path = imagePkgs.callPackage ../lib/packages/shadow-maint-hooks { };
  }
  {
    name = "nss";
    path = imagePkgs.nss-altfiles;
  }
  {
    name = "command-closure";
    path = pkgs.closureInfo { rootPaths = [ commands ]; };
  }
  {
    name = "baseline-accounts.json";
    path = pkgs.writeText "baseline-accounts.json" (
      builtins.toJSON (import ../lib/fs/nix-base/baseline-accounts.nix { inherit (pkgs) lib; })
    );
  }
  {
    name = "hm-files";
    path = image.componentFilesystems.home-manager;
  }
]
