{
  coreutils,
  gawk,
  lib,
  provision-user-home,
  writeShellScriptBin,
}:

writeShellScriptBin "seed-user-hm" ''
  export PATH=${
    lib.makeBinPath [
      coreutils
      gawk
      provision-user-home
    ]
  }:$PATH
  ${builtins.readFile ./seed-user-hm.sh}
''
