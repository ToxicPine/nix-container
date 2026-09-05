# Services every image provides in the root tree.
{ nixSupervise }:
{ pkgs, ... }:

let
  nixSupervisePackages = pkgs.callPackages "${nixSupervise}/pkgs" { };

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
  supervision.system.services.nix-daemon = {
    process.argv = [ "${nixDaemon}/bin/system-image-nix-daemon" ];
    s6 = {
      notificationFd = 3;
      timeoutUp = 60000;
    };
  };
}
