{
  coreutils,
  gawk,
  jq,
  registerUserTree,
  util-linuxMinimal,
  writeShellApplication,
}:

writeShellApplication {
  name = "system-image-activate-home-manager-users";
  runtimeInputs = [
    coreutils
    gawk
    jq
    registerUserTree
    util-linuxMinimal
  ];
  text = builtins.readFile ./activate-home-manager-users.sh;
}
