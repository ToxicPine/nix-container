{
  coreutils,
  findutils,
  gawk,
  lib,
  writeShellScriptBin,
}:

writeShellScriptBin "provision-user-home" ''
  export PATH=${
    lib.makeBinPath [
      coreutils
      findutils
      gawk
    ]
  }:$PATH
  ${builtins.readFile ./provision-user-home.sh}
''
