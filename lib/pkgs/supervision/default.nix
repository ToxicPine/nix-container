{
  nixSupervisionPackages,
  pkgs,
}:

let
  inherit (nixSupervisionPackages) treeRunner;

  registerUserTree = pkgs.callPackage ./register-user-tree {
    inherit treeRunner;
  };
  activateHomeManagerUsers = pkgs.callPackage ./activate-home-manager-users {
    inherit registerUserTree;
  };
  stopUserTrees = pkgs.callPackage ./stop-user-trees { };
  s6LinuxInit = import ./s6-linux-init {
    inherit
      activateHomeManagerUsers
      pkgs
      stopUserTrees
      ;
  };
in
{
  inherit (s6LinuxInit) installInitTreeCommands;
  inherit stopUserTrees;

  packages = [
    activateHomeManagerUsers
    registerUserTree
    stopUserTrees
    treeRunner
  ]
  ++ s6LinuxInit.packages;
}
