# Check the actual template image's closure registration and layer placement.
# nix-build tests/image.nix --no-out-link
let
  sources = import ../fs/hm-base/npins;
  pkgs = import sources.nixpkgs { };
  image = import ../nix { };
in
pkgs.runCommand "system-image-contract-tests"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.nix
    ];
  }
  ''
    python3 - ${image} ${image.imageRegistration}/store-paths ${image.factorySystemGeneration} <<'PY'
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
    PY
    # Check the actual boot input with Nix, without maintaining a second parser.
    export NIX_REMOTE="local?state=''${TMPDIR}/state&real=''${TMPDIR}/store"
    nix-store --load-db < ${image.imageRegistration}/registration
    nix --extra-experimental-features nix-command path-info --all | sort > registered-paths
    cmp ${image.imageRegistration}/store-paths registered-paths
    # Core identities are created at startup from a manifest, not rendered
    # into a second set of account database definitions in the image.
    for account_file in passwd group shadow gshadow subuid subgid; do
      test -f ${image.rootFilesystem}/etc/"$account_file"
      test ! -s ${image.rootFilesystem}/etc/"$account_file"
    done
    test ! -e ${image.rootFilesystem}/opt/defaults/accounts.json
    # The backend and HM component contribute hooks through their image layers.
    test -d ${image.rootFilesystem}/etc/shadow-maint/useradd-post.d
    test ! -L ${image.rootFilesystem}/etc/shadow-maint
    test ! -L ${image.rootFilesystem}/etc/shadow-maint/useradd-post.d
    test -x ${image.rootFilesystem}/etc/shadow-maint/useradd-post.d/50-provision-home
    test ! -e ${image.rootFilesystem}/etc/shadow-maint/useradd-post.d/60-home-manager
    test -x ${image.componentFilesystems.home-manager}/etc/shadow-maint/useradd-post.d/60-home-manager
    test -x ${image.componentFilesystems.home-manager}/etc/shadow-maint/userdel-pre.d/50-home-manager-services
    test -x ${image.componentFilesystems.home-manager}/etc/shadow-maint/userdel-post.d/50-home-manager
    test -f ${image.rootFilesystem}/opt/defaults/skel/.nixcfg/home.nix
    # Factory configs use the normal template copy, not component layers or links.
    test ! -e ${image.componentFilesystems.home-manager}/opt/defaults/hm-user
    test -f ${image.rootFilesystem}/opt/defaults/hm-user/user/home.nix
    test ! -L ${image.rootFilesystem}/opt/defaults/hm-user/user
    test "$(readlink ${image.rootFilesystem}/opt/app)" = /data/app
    test -x ${image.rootFilesystem}/opt/defaults/bin/refresh-system
    test ! -e ${image.rootFilesystem}/opt/defaults/hm-user/refresh.nix
    test ! -e ${image.rootFilesystem}/opt/defaults/scaffold/refresh.nix
    # Build-only HM sources are absent from the factory configuration.
    test ! -e ${image.rootFilesystem}/opt/defaults/nix/scripts/hooks
    test ! -e ${image.rootFilesystem}/opt/defaults/overlays/home-manager
    test -f ${image.rootFilesystem}/opt/defaults/nix/home-manager.nix
    touch "$out"
  ''
