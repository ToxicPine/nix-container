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
      _final: prev:
      infuse prev {
        components.home-manager.enable.__assign = false;
      }
    )
    imageOverlay
  ];
  base = evaluate [ ];
  hm = enabled.components.home-manager;
  addHook = hm.image.files."/etc/shadow-maint/useradd-post.d/60-home-manager";
  home = (import sources.home-manager { inherit pkgs; }).lib.homeManagerConfiguration {
    inherit pkgs;
    modules = [
      (import ../fs/hm-base { inherit sources; })
      {
        home.username = "alice";
        home.homeDirectory = "/home/alice";
        supervision.services = {
          automatic = {
            process.argv = [ "${pkgs.hello}/bin/hello" ];
            s6.restartOnChange = true;
          };
          default.process.argv = [ "${pkgs.hello}/bin/hello" ];
          nested.services = {
            default.process.argv = [ "${pkgs.hello}/bin/hello" ];
            automatic = {
              process.argv = [ "${pkgs.hello}/bin/hello" ];
              s6.restartOnChange = true;
            };
          };
          manual = {
            process.argv = [ "${pkgs.hello}/bin/hello" ];
            s6.restartOnChange = false;
          };
        };
      }
    ];
  };
in
assert !home.config.supervision.services.default.s6.restartOnChange;
assert !home.config.supervision.services.nested.services.default.s6.restartOnChange;
assert home.config.supervision.services.nested.services.automatic.s6.restartOnChange;
assert home.config.supervision.services.automatic.s6.restartOnChange;
assert !home.config.supervision.services.manual.s6.restartOnChange;
assert disabled.generation.drvPath == base.generation.drvPath;
assert (evaluate [ imageOverlay ]).generation.drvPath == base.generation.drvPath;
assert runtime.generation.drvPath == enabled.generation.drvPath;
assert runtime.components.home-manager.image.files == { };
assert !(hm ? files);
assert !(hm ? seeds);
assert !(hm.image.trees ? "/opt/defaults/skel/.nixcfg");
assert !(hm.services ? home-alice);
assert enabled.config.supervision.system.services.tree-alice.s6.dependencies == { };
pkgs.runCommand "home-manager-hook-tests" { } ''
  test -x ${addHook}
  test -x ${hm.image.files."/etc/shadow-maint/userdel-pre.d/50-home-manager-services"}
  test -x ${hm.image.files."/etc/shadow-maint/userdel-post.d/50-home-manager"}
  touch "$out"
''
