{
  coreutils,
  gawk,
  s6,
  writeShellApplication,
}:

writeShellApplication {
  name = "system-image-stop-user-trees";
  runtimeInputs = [
    coreutils
    gawk
    s6
  ];
  text = builtins.readFile ./stop-user-trees.sh;
}
