# Evaluate the root supervision configuration into a generation. The image
# build and the runtime refresh both call this with the system configuration
# and the pins; neither location is assumed, so the file works from the
# repository and from /opt/app alike. The base provides s6 init's root tree,
# the Nix daemon, and account operations; anything else, Home Manager
# included, is a module the system configuration imports.
{
  pkgs,
  sources,
  modules,
}:

import "${sources.nix-supervise}/lib/eval-system-services.nix" {
  inherit pkgs;
  modules = [
    ./tree.nix
    (import ./services.nix { nixSupervise = sources.nix-supervise; })
    ./users.nix
  ]
  ++ modules;
  specialArgs = { inherit sources; };
}
