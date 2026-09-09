# nix-instantiate --eval --strict tests/scaffold.nix
let
  sources = import ../fs/hm-base/npins;
  pkgs = import sources.nixpkgs {
    overlays = [ (import ../fs/overlay.nix) ];
    config.allowUnfree = true;
  };
  evaluate =
    overlays:
    import ../lib/fs/scaffold {
      inherit
        pkgs
        sources
        overlays
        ;
    };
  base = evaluate [ ];
  ordered = evaluate [
    ../fs/nix/system.nix
    (
      { infuse, ... }:
      _final: prev:
      infuse prev {
        image.name.__assign = "first";
        image.exposedPorts.__append = [ 8000 ];
      }
    )
    (
      { infuse, ... }:
      _final: prev:
      infuse prev {
        image.name.__assign = prev.image.name + "-last";
        image.exposedPorts.__append = [ 9000 ];
      }
    )
  ];
  finalPackages = evaluate [
    ({ pkgs, sources, ... }: final: _prev: {
      components.injected.packages = [ pkgs.hello ];
      components.example = final.callComponent ({ pkgs }: { packages = [ pkgs.hello ]; }) { };
      image.name = sources.testName;
      image.exposedPorts = [ ];
    })
    (_: _final: prev: {
      pkgs = prev.pkgs // {
        hello = prev.pkgs.bash;
      };
      sources = prev.sources // {
        testName = "final-sources";
      };
    })
  ];
  example = evaluate [
    (
      { infuse, ... }:
      final: prev:
      infuse prev {
        components.demo.__init = final.callComponent (
          {
            greeting ? "hello",
          }:
          {
            image.files."/etc/greeting" = pkgs.writeText "greeting" greeting;
            image.files."/etc/shadow-maint/useradd-post.d/60-demo" =
              pkgs.writeShellScript "demo-hook" "echo hook";
            packages = [ pkgs.hello ];
            users.demo.uid = 1234;
            services.demo.process.argv = [ "${pkgs.hello}/bin/hello" ];
            services.automatic = {
              process.argv = [ "${pkgs.hello}/bin/hello" ];
              s6.restartOnChange = true;
            };
            services.nested.services = {
              default.process.argv = [ "${pkgs.hello}/bin/hello" ];
              automatic = {
                process.argv = [ "${pkgs.hello}/bin/hello" ];
                s6.restartOnChange = true;
              };
            };
            services.manual = {
              process.argv = [ "${pkgs.hello}/bin/hello" ];
              s6.restartOnChange = false;
            };
          }
        ) { };
      }
    )
    (
      { infuse, ... }:
      _final: prev: infuse prev { components.demo.__input.greeting.__assign = "changed"; }
    )
  ];
  lazyImage = evaluate [
    (
      { infuse, ... }:
      _final: prev:
      infuse prev {
        components.example.__init.image = throw "runtime forced image-only configuration";
      }
    )
  ];
  disabled = evaluate [
    (_: _final: _prev: {
      components.off = {
        enable = false;
        users = throw "disabled users forced";
        image = throw "disabled image forced";
      };
    })
  ];
  fails =
    configuration:
    !(builtins.tryEval (builtins.deepSeq (evaluate [ configuration ]).generation.drvPath true)).success;
in
assert ordered.users.user.uid == 1000;
assert ordered.image.name == "first-last";
assert
  ordered.image.exposedPorts == [
    8000
    9000
  ];
assert finalPackages.packages == [ pkgs.bash ];
assert finalPackages.image.name == "final-sources";
assert
  toString example.components.demo.image.files."/etc/greeting"
  == toString (pkgs.writeText "greeting" "changed");
assert example.users.demo.uid == 1234;
assert example.groups.demo.gid == 1234;
assert example.components.demo.image.files ? "/etc/shadow-maint/useradd-post.d/60-demo";
assert !(example.config.supervision.system.services.demo.s6.dependencies ? system-resources);
assert example.config.supervision.system.services.nested.services.default.s6.dependencies == { };
assert !(example.config.supervision.system.services.nix-daemon.s6.dependencies ? system-resources);
assert !(example.config.supervision.system.services ? system-resources);
assert !example.config.supervision.system.services.demo.s6.restartOnChange;
assert example.config.supervision.system.services.automatic.s6.restartOnChange;
assert !example.config.supervision.system.services.nested.services.default.s6.restartOnChange;
assert example.config.supervision.system.services.nested.services.automatic.s6.restartOnChange;
assert !example.config.supervision.system.services.manual.s6.restartOnChange;
assert lazyImage.generation.drvPath == base.generation.drvPath;
assert !(disabled.components ? off);
assert fails (_: _final: _prev: { boot.rebuildOnBoot = true; });
assert
  !(builtins.tryEval
    (evaluate [
      (_: _final: _prev: { imagge.name = "misspelled"; })
    ]).generation.drvPath
  ).success;
assert fails (
  _: _final: _prev: {
    components.one.users.duplicate.uid = 1000;
    components.two.users.duplicate.uid = 1000;
  }
);
assert fails (_: _final: _prev: { components.bad.packgaes = [ ]; });
assert fails (_: _final: _prev: { components.bad.users.sshd.uid = 65533; });
assert fails (_: _final: _prev: { components.bad.users.impostor.uid = 30001; });
assert fails (_: _final: _prev: { components.bad.groups.nixbld.gid = 30000; });

assert fails (
  _: _final: _prev: {
    components.bad.users.a.uid = 1000;
    components.bad.groups.a.gid = 1001;
  }
);
assert fails (
  _: _final: _prev: {
    components.bad.users.a.uid = 1000;
    components.bad.users.b.uid = 1000;
  }
);
assert fails (
  _: _final: _prev: {
    components.bad.groups.a.gid = 1000;
    components.bad.groups.b.gid = 1000;
  }
);
assert fails (
  _: _final: _prev: {
    components.bad.users.a = {
      uid = 1000;
      extraGroups = [ "undeclared" ];
    };
  }
);
# Runtime file management and generic seeding are intentionally unsupported.
assert fails (_: _final: _prev: { components.bad.files = { }; });
assert fails (_: _final: _prev: { components.bad.seeds = { }; });
assert fails (
  _: _final: _prev: {
    components.bad.services.demo = {
      process.argv = [ "/bin/true" ];
      s6.notificationFd = 2;
    };
  }
);
{
  scaffold = "passed";
}
