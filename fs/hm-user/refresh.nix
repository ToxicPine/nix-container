{
  user,
  system ? builtins.currentSystem,
}:

let
  sources = import ../hm-base/npins;
  pkgs = import sources.nixpkgs {
    localSystem.system = system;
    config.allowUnfree = true;
    overlays = [ (import ../overlay.nix) ];
  };
  home-manager = import sources.home-manager { inherit pkgs; };
  homeModule = ./. + "/${user}/home.nix";
in
(home-manager.lib.homeManagerConfiguration {
  inherit pkgs;
  modules = [
    homeModule
    {
      home.username = user;
      home.homeDirectory = "/home/${user}";
    }
  ];
}).activationPackage
