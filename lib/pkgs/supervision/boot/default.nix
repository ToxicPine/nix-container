{
  coreutils,
  treeRunner,
  writeShellApplication,
}:

writeShellApplication {
  name = "system-image-boot";
  runtimeInputs = [
    coreutils
    treeRunner
  ];
  text = builtins.readFile ./boot.sh;
}
