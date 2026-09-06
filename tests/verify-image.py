"""Verify image output against the mutable-store bootstrap contract."""
import json
from pathlib import Path
import sys

image = json.loads(Path(sys.argv[1]).read_text())
registered = set(Path(sys.argv[2]).read_text().splitlines())
generation = sys.argv[3]
seen, relocated = set(), set()
for layer in image["layers"]:
    for entry in layer["paths"]:
        path = entry["path"]
        assert path not in seen, f"store path repeated across layers: {path}"
        seen.add(path)
        if entry.get("options", {}).get("rewrite", {}).get("repl") == "/nix-base/":
            relocated.add(path)
        else:
            assert not (Path(path) / "nix-base/var/nix/db/db.sqlite").exists(), "temporary database shipped"
assert registered == relocated, {
    "missing registrations": sorted(relocated - registered),
    "registered but absent": sorted(registered - relocated),
}
assert generation in {entry["path"] for entry in image["layers"][-1]["paths"]}
print(f"{len(image['layers'])} layers: no repeated paths; complete registration; generation in final layer")
