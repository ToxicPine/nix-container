# Copied into the container as ~/.nixcfg/home.nix beside home-extras.nix.
_: {
  imports = [
    (import ../../hm-base { })
    ./extras.nix
  ];
}
