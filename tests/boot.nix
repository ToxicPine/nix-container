# Exercise boot generation selection without starting a container.
# nix-build tests/boot.nix --no-out-link
let
  sources = import ../fs/hm-base/npins;
  pkgs = import sources.nixpkgs { };
in
pkgs.runCommand "system-image-boot-tests"
  {
    script = ../lib/packages/supervision/s6-linux-init/skeleton/rc.init;
    inherit (pkgs) runtimeShell;
  }
  ''
    set -euo pipefail
    root=$PWD/root
    mkdir -p "$root/tools" "$root/environment"
    chmod 0700 "$root/environment"

    # Relocate only the image's fixed paths; execute the production script.
    cp "$script" rc.init
    relocate() {
      local declaration="$1=\"$2\""
      test "$(grep -c -F -- "$declaration" rc.init)" = 1
      sed -i "s|$declaration|$1=\"$3\"|" rc.init
    }
    relocate runtime_directory /run/nix-supervise/system "$root/runtime"
    relocate profile /nix/var/nix/profiles/system "$root/profile"
    relocate factory_generation /opt/defaults/system-generation "$root/factory"
    relocate environment_dump /run/s6-linux-init-env "$root/environment"

    tool() {
      printf '#!%s\n%s\n' "$runtimeShell" "$2" > "$root/tools/$1"
      chmod 0755 "$root/tools/$1"
    }
    tool nix-supervise-tree-wait 'exit 0'
    # Generation application must still go through s6-envdir.
    tool s6-envdir 'test "$1" = -I && test "$2" = -f && test "$3" = "'"$root/environment"'" || exit 99
    shift 3
    exec "$@"'
    generation() {
      mkdir -p "$1/bin"
      printf '#!%s\necho %s >> "%s"\nexit %s\n' "$runtimeShell" "$2" "$root/calls" "$3" > "$1/bin/apply"
      chmod 0755 "$1/bin/apply"
    }
    reset() { rm -rf "$root/calls" "$root/profile" "$root/selected" "$root/factory"; }
    boot() {
      status=0
      PATH="$root/tools:$PATH" sh rc.init > "$root/output" 2>&1 || status=$?
    }
    calls() { cat "$root/calls" 2>/dev/null || true; }
    expect() {
      if test "$1" != "$2"; then
        echo "expected '$2', got '$1'" >&2
        cat "$root/output" >&2
        exit 1
      fi
    }

    # A selected generation is applied once, and the environment dump becomes
    # readable to the user activations that need it.
    reset
    generation "$root/selected" selected 0
    ln -s "$root/selected" "$root/profile"
    generation "$root/factory" factory 0
    boot; expect "$status" 0; expect "$(calls)" selected
    expect "$(stat -c %a "$root/environment")" 755

    # A failed selected transition never falls back to the factory generation.
    reset
    generation "$root/selected" selected 42
    ln -s "$root/selected" "$root/profile"
    generation "$root/factory" factory 0
    boot; expect "$status" 42; expect "$(calls)" selected

    # A missing or dangling profile uses the factory generation.
    reset
    generation "$root/factory" factory 0
    boot; expect "$status" 0; expect "$(calls)" factory
    rm "$root/calls"
    ln -s "$root/missing-generation" "$root/profile"
    boot; expect "$status" 0; expect "$(calls)" factory

    # A factory failure is reported.
    reset
    generation "$root/factory" factory 43
    boot; expect "$status" 43; expect "$(calls)" factory

    # No generation at all fails without applying anything.
    reset
    boot; expect "$status" 1; expect "$(calls)" ""

    # An unready root tree applies nothing.
    reset
    generation "$root/factory" factory 0
    tool nix-supervise-tree-wait 'exit 1'
    boot; expect "$status" 1; expect "$(calls)" ""

    touch "$out"
  ''
