# One account application program, used by early bootstrap and runtime refresh.
{ pkgs }:
pkgs.writeShellApplication {
  name = "system-reconcile-accounts";
  extraShellCheckFlags = [ "--enable=all" ];
  inheritPath = false;
  runtimeInputs = [
    pkgs.coreutils
    pkgs.gawk
    pkgs.jq
    pkgs.util-linux
    pkgs.s6-rc
  ];
  text = ''
    export PATH="''${PATH}:/run/current-system/sw/bin:/bin:/sbin:/usr/bin:/usr/sbin"
    account_lib=${./scripts}
  ''
  + builtins.readFile ./scripts/reconcile-accounts.sh;
}
