{
  coreutils,
  gawk,
  lib,
  writeShellScriptBin,
}:

writeShellScriptBin "provision-user-home" ''
  export PATH=${
    lib.makeBinPath [
      coreutils
      gawk
    ]
  }:$PATH
  ${builtins.readFile ./provision-user-home.sh}
''
