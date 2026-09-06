{
  nixSupervisionPackages,
  pkgs,
}:

let
  inherit (nixSupervisionPackages) treeRunner;

  s6LinuxInit = import ./s6-linux-init {
    inherit pkgs treeRunner;
  };
in
{
  inherit (s6LinuxInit) installInitTreeCommands;

  packages = [ nixSupervisionPackages.runtimeTools ] ++ s6LinuxInit.packages;
}
