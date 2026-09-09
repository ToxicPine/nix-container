# Boot the real image under podman inside a NixOS VM and drive its lifecycle:
# first boot, root refresh, user refresh, restart, and reset.
# nix-build tests/vm.nix --no-out-link
let
  sources = import ../fs/hm-base/npins;
  pkgs = import sources.nixpkgs { };
  image = import ../nix { };

  # The guest has no network and the container's store starts from the image,
  # so everything refresh-system will build inside the container is built
  # here with the same inputs and copied into the container's /nix volume.
  runtimePkgs = import sources.nixpkgs {
    localSystem.system = "x86_64-linux";
    config.allowUnfree = true;
    overlays = [ (import ../fs/overlay.nix) ];
  };
  homeManager = import sources.home-manager { pkgs = runtimePkgs; };
  homeGeneration =
    name: modules:
    (homeManager.lib.homeManagerConfiguration {
      pkgs = runtimePkgs;
      modules = modules ++ [
        {
          home.username = name;
          home.homeDirectory = "/home/${name}";
        }
      ];
    }).activationPackage;
  withCarol =
    port:
    import ../lib/fs/scaffold {
      pkgs = runtimePkgs;
      inherit sources;
      overlays = [
        ../fs/nix/system.nix
        (
          { infuse, ... }:
          _final: prev:
          infuse prev {
            components.home-manager.__input.users.carol.__init = {
              uid = 1002;
            };
            components.local.services.nested.__init.services.worker = {
              process.argv = [
                "${runtimePkgs.coreutils}/bin/sleep"
                "infinity"
              ];
              s6.execution.user = "carol";
            };
            components.local.services.metrics.__init = {
              s6.restartOnChange = true;
              process.argv = [
                "${runtimePkgs.python3}/bin/python"
                "-m"
                "http.server"
                port
              ];
            };
          }
        )
      ];
    };
  runtimeClosure = pkgs.closureInfo {
    rootPaths = [
      (withCarol "9100").generation
      (withCarol "9101").generation
      (homeGeneration "carol" [ ../fs/skel/.nixcfg/home.nix ])
      (homeGeneration "user" [
        ../fs/skel/.nixcfg/home.nix
        ./vm/home-extras.nix
      ])
      (homeGeneration "user" [
        ../fs/skel/.nixcfg/home.nix
        (builtins.toFile "home-extras.nix" (
          builtins.replaceStrings [ "8080" ] [ "8081" ] (builtins.readFile ./vm/home-extras.nix)
        ))
      ])
      "${sources.nixpkgs}"
      "${sources.home-manager}"
      "${sources.nix-supervise}"
    ];
  };
in
pkgs.testers.runNixOSTest {
  name = "system-image-lifecycle";
  nodes.machine = _: {
    virtualisation = {
      podman.enable = true;
      cores = 4;
      memorySize = 4096;
      diskSize = 12288;
      additionalPaths = [
        image.copyToPodman
        runtimeClosure
      ];
    };
    nix.settings.experimental-features = [ "nix-command" ];
  };
  testScript = ''
    import shlex

    def sh(command, user=None):
        exec_options = "" if user is None else f"--user {user} --env HOME=/home/user --env USER=user"
        return machine.succeed(f"podman exec {exec_options} sys bash -c {shlex.quote(command)}")

    def services():
        return sh("s6-rc -l /run/nix-supervise/system/live -a list")

    def service_pid(option_path):
        name = sh("jq -r --arg path " + shlex.quote(option_path) +
                  " '.services | to_entries[] | select(.value.optionPath == $path) | .key' "
                  "/run/nix-supervise/system/current-service-manifest.json").strip()
        assert name, f"missing service {option_path}"
        return sh(f"s6-svstat -o pid /run/nix-supervise/system/scan/{name}").strip()

    def wait_for_port(port):
        machine.wait_until_succeeds(
            f"podman exec sys bash -c 'exec 3<>/dev/tcp/127.0.0.1/{port}'", timeout=60
        )

    def wait_for_boot():
        try:
            machine.wait_until_succeeds(
                "podman exec sys s6-rc -l /run/nix-supervise/system/live -a list | grep -q apply-user",
                timeout=600,
            )
        except Exception:
            print(machine.succeed(
                "podman inspect sys --format '{{.State.Status}} exit={{.State.ExitCode}}'; "
                "podman logs sys 2>&1 | tail -80"
            ))
            raise

    machine.wait_for_unit("multi-user.target")

    with subtest("first boot from empty volumes"):
        machine.succeed("${image.copyToPodman}/bin/copy-to-podman")
        machine.succeed(
            "nix copy --no-check-sigs --to 'local?root=/var/lib/nix-volume' "
            "$(cat ${runtimeClosure}/store-paths)"
        )
        machine.succeed("mkdir -p /var/lib/data-volume")
        machine.succeed(
            "podman run --detach --name sys "
            "--volume /var/lib/nix-volume/nix:/nix --volume /var/lib/data-volume:/data "
            "system-image:latest"
        )
        wait_for_boot()
        assert sh("id -u user").strip() == "1000"
        sh("test -f /home/user/.nixcfg/home.nix")
        sh("test /opt/app -ef /data/app")

    with subtest("the whole working tree is mutable"):
        for path in ["overlay.nix", "hm-base/default.nix", "skel/.nixcfg/home.nix"]:
            sh(f"printf '\\n# persistent edit\\n' >> /opt/app/{path}")
        sh("printf '\\n ' >> /opt/app/hm-base/npins/sources.json")
        sh("printf '#!/bin/sh\\necho persistent\\n' > /opt/app/bin/persistence-check; "
           "chmod +x /opt/app/bin/persistence-check")
        persistent_paths = ("/opt/app/overlay.nix /opt/app/hm-base/default.nix "
                            "/opt/app/hm-base/npins/sources.json /opt/app/skel/.nixcfg/home.nix "
                            "/opt/app/bin/persistence-check")
        working_tree_hashes = sh("sha256sum " + persistent_paths)

    with subtest("the daemon builds as a bootstrapped build user"):
        result = sh(
            "nix-build --option substituters \"\" --no-out-link --expr "
            "'builtins.derivation { name = \"build-user-check\"; system = builtins.currentSystem; "
            "builder = \"/bin/sh\"; args = [ \"-c\" \"/bin/id -u > $out\" ]; }'"
        ).strip()
        build_uid = int(sh(f"cat {result}"))
        assert build_uid in range(30001, 30011), f"build ran as uid {build_uid}"

    with subtest("root refresh adds accounts before services without restarting existing users"):
        user_tree_pid = service_pid("tree-user")
        sh(r"sed -i 's|users.user.uid = 1000;|users.user.uid = 1000;\n    users.carol.uid = 1002;|' "
           "/opt/app/nix/system.nix")
        sh(r"sed -i '/# services.metrics.process.argv = /,+2 s/# //' /opt/app/nix/system.nix")
        sh(r"sed -i '/services.metrics.process.argv = /i\    services.metrics.s6.restartOnChange = true;' "
           "/opt/app/nix/system.nix")
        sh(r"sed -i '/services.metrics.process.argv = /i\    services.nested.services.worker = { "
           r'process.argv = [ "${runtimePkgs.coreutils}/bin/sleep" "infinity" ]; '
           r's6.execution.user = "carol"; };' + "' /opt/app/nix/system.nix")
        sh("refresh-system")
        assert service_pid("tree-user") == user_tree_pid
        assert "system-resources" not in services()
        worker_pid = service_pid("nested.worker")
        assert sh(f"stat -c %u /proc/{worker_pid}").strip() == "1002"
        wait_for_port(9100)
        assert sh("id -u carol").strip() == "1002"
        sh("grep -q 'persistent edit' /home/carol/.nixcfg/home.nix")
        assert "apply-carol" in services()
        sh("test -f /home/carol/.local/state/nix/profiles/home-manager/activate")

    with subtest("a user adds a package and a service"):
        machine.succeed("podman cp ${./vm/home-extras.nix} sys:/home/user/.nixcfg/extras.nix")
        machine.succeed("podman cp ${./vm/home.nix} sys:/home/user/.nixcfg/home.nix")
        sh("chown user:user /home/user/.nixcfg/home.nix /home/user/.nixcfg/extras.nix")
        sh("refresh-system", user="1000:1000")
        assert "Hello, world!" in sh("/home/user/.nix-profile/bin/hello", user="1000:1000")
        wait_for_port(8080)

    with subtest("service command edits take effect on refresh"):
        sh("sed -i 's/9100/9101/g' /opt/app/nix/system.nix && refresh-system")
        wait_for_port(9101)
        machine.fail("podman exec sys bash -c 'exec 3<>/dev/tcp/127.0.0.1/9100'")
        sh("sed -i 's/8080/8081/g' /home/user/.nixcfg/extras.nix && refresh-system", user="1000:1000")
        wait_for_port(8081)
        machine.fail("podman exec sys bash -c 'exec 3<>/dev/tcp/127.0.0.1/8080'")
        saved_generation = sh("readlink -f /nix/var/nix/profiles/system")

    with subtest("restart applies the saved generation without evaluating Nix"):
        machine.succeed("podman stop sys")
        machine.succeed("podman start sys")
        wait_for_boot()
        assert saved_generation == sh("readlink -f /nix/var/nix/profiles/system")
        assert "apply-carol" in services()
        since_boot = machine.succeed("podman logs sys 2>&1").rsplit("rc.init: applying generation", 1)[1]
        assert "building '" not in since_boot, since_boot
        wait_for_port(9101)
        wait_for_port(8081)

    with subtest("the working tree and user links survive container replacement"):
        machine.succeed("podman rm --force sys")
        machine.succeed(
            "podman run --detach --name sys "
            "--volume /var/lib/nix-volume/nix:/nix --volume /var/lib/data-volume:/data "
            "system-image:latest"
        )
        wait_for_boot()
        sh("test -L /opt/app/hm-user/user && test -L /opt/app/hm-user/carol")
        assert sh("sha256sum " + persistent_paths) == working_tree_hashes
        assert sh("/opt/app/bin/persistence-check").strip() == "persistent"
        sh("test /opt/app/hm-user/user/home.nix -ef /home/user/.nixcfg/home.nix")
        sh("test /opt/app/hm-user/carol/home.nix -ef /home/carol/.nixcfg/home.nix")
        wait_for_port(8081)
        sh("refresh-system", user="1000:1000")
        wait_for_port(8081)

    with subtest("reset stops removed-user services and retains unrelated user trees"):
        user_tree_pid = service_pid("tree-user")
        worker_pid = service_pid("nested.worker")
        sh("cd /opt/app/nix && reset-system")
        sh("cmp /opt/app/nix/system.nix /opt/defaults/nix/system.nix")
        for path in ["overlay.nix", "hm-base/default.nix", "hm-base/npins/sources.json",
                     "skel/.nixcfg/home.nix"]:
            sh(f"cmp /opt/app/{path} /opt/defaults/{path}")
        sh("test ! -e /opt/app/bin/persistence-check")
        sh("test /opt/app/hm-user/user/home.nix -ef /home/user/.nixcfg/home.nix")
        sh("test -f /home/user/.nixcfg/extras.nix")
        assert "carol:" not in sh("cat /data/etc/passwd")
        sh(f"test ! -e /proc/{worker_pid}")
        assert service_pid("tree-user") == user_tree_pid
        sh("test -d /data/homes/carol && test ! -e /run/nix-supervise/users/1002")
        assert "carol" not in services()
        assert "apply-user" in services()
  '';
}
