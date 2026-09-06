# A small real n2c image tests explicit deduplication, relocation, and reuse.
# nix-build tests/layers.nix --no-out-link
let
  sources = import ../fs/hm-base/npins;
  pkgs = import sources.nixpkgs { };
  inherit (pkgs) lib;
  n2c = import ../n2c { inherit pkgs; };
  shared = pkgs.writeText "layer-shared" "shared dependency";
  first = pkgs.writeText "layer-first" "first references ${shared}";
  second = pkgs.writeText "layer-second" "second references ${shared}";
  last = value: pkgs.writeText "layer-last" "${value} references ${shared}";
  prefix = "/nix-base";
  make =
    value:
    n2c.buildImage {
      name = "layer-regression";
      nixStorePrefix = prefix;
      layers =
        ((import ../lib/build-oci-layers.nix { inherit lib n2c; }) [
          {
            name = "first";
            deps = [ first ];
            nixStorePrefix = prefix;
          }
          {
            name = "second";
            deps = [ second ];
            nixStorePrefix = prefix;
          }
          {
            name = "last";
            deps = [ (last value) ];
            nixStorePrefix = prefix;
          }
        ]).layers;
    };

in
pkgs.runCommand "system-component-layer-tests" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  python3 ${./verify-layers.py} ${make "before"} ${make "after"} ${shared}
  touch "$out"
''
