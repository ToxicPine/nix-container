# nix-build tests/home-manager.nix --no-out-link
let
  sources = import ../fs/hm-base/npins;
  pkgs = import sources.nixpkgs { };
  evaluate =
    overlays:
    import ../lib/fs/scaffold {
      inherit
        pkgs
        sources
        overlays
        ;
    };
  configuration =
    { infuse, ... }:
    final: prev:
    infuse prev {
      components.home-manager.__init = final.callComponent ../fs/nix/home-manager.nix {
        users.alice.uid = 1000;
      };
    };
  imageOverlay = import ../lib/overlays/home-manager { buildProfiles = false; };
  runtime = evaluate [ configuration ];
  enabled = evaluate [
    configuration
    imageOverlay
  ];
  disabled = evaluate [
    configuration
    (
      { infuse, ... }:
      final: prev:
      infuse prev {
        components.home-manager.enable.__assign = false;
      }
    )
    imageOverlay
  ];
  base = evaluate [ ];
  hm = enabled.components.home-manager;
  addHook = hm.image.files."/etc/shadow-maint/useradd-post.d/60-home-manager";
in
assert disabled.generation.drvPath == base.generation.drvPath;
assert (evaluate [ imageOverlay ]).generation.drvPath == base.generation.drvPath;
assert runtime.generation.drvPath == enabled.generation.drvPath;
assert runtime.components.home-manager.image.files == { };
assert !(hm ? files);
assert !(hm ? seeds);
assert !(hm.image.trees ? "/opt/defaults/skel/.nixcfg");
assert !(hm.services ? home-alice);
assert enabled.config.supervision.system.services.tree-alice.s6.dependencies ? system-resources;
pkgs.runCommand "home-manager-hook-tests" { } ''
  test -x ${addHook}
  test -x ${hm.image.files."/etc/shadow-maint/userdel-pre.d/50-home-manager-services"}
  test -x ${hm.image.files."/etc/shadow-maint/userdel-post.d/50-home-manager"}
  touch "$out"
''
