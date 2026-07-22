{ pkgs }:

let
  sources = import ./npins;
  patchedSource = pkgs.applyPatches {
    name = "n2c-source";
    src = sources.nix2container;
    patches = [ ./nix-store-prefix.patch ];
  };
in
(import patchedSource { inherit pkgs; }).nix2container
