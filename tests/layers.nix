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
      inherit
        (
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
          ])
        )
        layers
        ;
    };

in
pkgs.runCommand "system-component-layer-tests" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  python3 - ${make "before"} ${make "after"} ${shared} <<'PY'
  import json
  import sys

  before, after = [json.load(open(path)) for path in sys.argv[1:3]]
  shared = sys.argv[3]
  for image in (before, after):
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
  print("Explicit layer deduplication, relocation and unchanged-layer reuse passed")
  PY
  touch "$out"
''
