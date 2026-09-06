# The default component supplies the Nix daemon. Site overlays can override it.
{ pkgs, sources, ... }:
let
  nixSupervisePackages = pkgs.callPackages "${sources.nix-supervise}/pkgs" { };
  nixDaemon = pkgs.writeShellApplication {
    name = "system-image-nix-daemon";
    runtimeInputs = [
      pkgs.execline
      pkgs.nix
      nixSupervisePackages.s6
    ];
    text = builtins.readFile ./scripts/nix-daemon.sh;
  };
in
{
  image.order = 0;
  services.nix-daemon = {
    process.argv = [ "${nixDaemon}/bin/system-image-nix-daemon" ];
    s6 = {
      notificationFd = 3;
      timeoutUp = 60000;
    };
  };
}
