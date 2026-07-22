{
  coreutils,
  s6,
  treeRunner,
  writeShellApplication,
}:

writeShellApplication {
  name = "system-image-register-user-tree";
  runtimeInputs = [
    coreutils
    s6
    treeRunner
  ];
  text = builtins.readFile ./register-user-tree.sh;
}
