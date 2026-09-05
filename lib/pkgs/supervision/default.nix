{
  nixSupervisionPackages,
  pkgs,
}:

let
  inherit (nixSupervisionPackages) treeRunner;

  boot = pkgs.callPackage ./boot {
    inherit treeRunner;
  };
  s6LinuxInit = import ./s6-linux-init {
    inherit boot pkgs treeRunner;
  };
in
{
  inherit (s6LinuxInit) installInitTreeCommands;

  packages = [
    boot
    nixSupervisionPackages.runtimeTools
  ]
  ++ s6LinuxInit.packages;
}
