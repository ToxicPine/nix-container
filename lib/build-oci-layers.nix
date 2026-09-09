# Follow the explicit-layer fold linked from upstream n2c's README:
# https://blog.eigenvalue.net/2023-nix2container-everything-once/
# Every layer needs the complete list of preceding layers for path exclusion.
{ lib, n2c }:
definitions:
lib.foldl'
  (
    state: definition:
    let
      rawLayer = n2c.buildLayer (
        (builtins.removeAttrs definition [ "name" ])
        // {
          inherit (state) layers;
        }
      );
      # Bound inherited metadata before later layers expand it again.
      # Workaround: https://github.com/nlewo/nix2container/issues/205
      layer = rawLayer // {
        nestedLayers = lib.unique rawLayer.nestedLayers;
      };
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
