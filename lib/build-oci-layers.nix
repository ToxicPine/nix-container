# Follow the explicit-layer fold linked from upstream n2c's README:
# https://blog.eigenvalue.net/2023-nix2container-everything-once/
# Every layer needs the complete list of preceding layers for path exclusion.
{ lib, n2c }:
definitions:
lib.foldl'
  (
    state: definition:
    let
      layer = n2c.buildLayer (
        (builtins.removeAttrs definition [ "name" ])
        // {
          layers = state.layers;
        }
      );
    in
    {
      layers = state.layers ++ [ layer ];
      byName = state.byName // {
        ${definition.name} = layer;
      };
    }
  )
  {
    layers = [ ];
    byName = { };
  }
  definitions
