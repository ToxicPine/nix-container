# Real n2c images test explicit deduplication, relocation, reuse, and scaling.
# nix-build tests/layers.nix --no-out-link
let
  sources = import ../fs/hm-base/npins;
  pkgs = import sources.nixpkgs { };
  inherit (pkgs) lib;
  n2c = import ../n2c { inherit pkgs; };
  buildLayers = import ../lib/build-oci-layers.nix { inherit lib n2c; };
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
      inherit
        (
          (buildLayers [
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
          ])
        )
        layers
        ;
    };
  # This many explicit layers previously exhausted the image command's
  # argument limit through repeated nestedLayers metadata (upstream #205).
  many = n2c.buildImage {
    name = "layer-scaling-regression";
    nixStorePrefix = prefix;
    layers =
      (buildLayers (
        lib.genList (index: {
          name = "part-${toString index}";
          deps = [ (pkgs.writeText "layer-part-${toString index}" "references ${shared}") ];
          nixStorePrefix = prefix;
        }) 15
      )).layers;
  };

in
pkgs.runCommand "system-component-layer-tests" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  python3 - ${make "before"} ${make "after"} ${many} ${shared} <<'PY'
  import json
  import sys

  before, after, many = [json.load(open(path)) for path in sys.argv[1:4]]
  shared = sys.argv[4]
  for image in (before, after, many):
      seen = set()
      for layer in image["layers"]:
          for entry in layer["paths"]:
              path = entry["path"]
              assert path not in seen, f"store path repeated across layers: {path}"
              seen.add(path)
              assert entry["options"]["rewrite"]["repl"] == "/nix-base/", entry
      assert shared in seen
  before_layers = [l for l in before["layers"] if l["paths"]]
  after_layers = [l for l in after["layers"] if l["paths"]]
  assert len(before_layers) == len(after_layers) == 3
  assert [l["digest"] for l in before_layers[:2]] == [l["digest"] for l in after_layers[:2]]
  assert before_layers[2]["digest"] != after_layers[2]["digest"]
  assert len([l for l in many["layers"] if l["paths"]]) == 15
  print("Explicit layer deduplication, relocation, unchanged-layer reuse and 15-layer build passed")
  PY
  touch "$out"
''
