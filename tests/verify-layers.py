"""Check actual n2c output, rather than the Nix expressions constructing it."""
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
