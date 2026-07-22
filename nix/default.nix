{
  system ? "x86_64-linux",
  sources ? import ../fs/hm-base/npins,
}:

let
  pkgs = import sources.nixpkgs {
    localSystem.system = system;
    config.allowUnfree = true;
    overlays = [ (import ../fs/overlay.nix) ];
  };
  home-manager = import sources.home-manager { inherit pkgs; };
  nixSupervisionPackages = pkgs.callPackages "${sources.nix-supervise}/pkgs" { };
  n2c = import ../n2c { inherit pkgs; };

  systemConfig = import ./system.nix { inherit pkgs; };

  declaredUsers = {
    user = {
      uid = 1000;
    };
  };

  hmPolicy = {
    buildProfiles = true;
    activateOnBoot = true;
    rebuildOnBoot = true;
  };

  hm = import ../lib/hm.nix {
    inherit
      pkgs
      home-manager
      declaredUsers
      hmPolicy
      ;
  };
in
import ../lib/image.nix {
  inherit pkgs n2c;
  supervisionPackages = nixSupervisionPackages;
  system = systemConfig;
  inherit declaredUsers;
  inherit (hm) runtime;
}
