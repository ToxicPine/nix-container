{
  activateHomeManagerUsers,
  pkgs,
  stopUserTrees,
}:

let
  inherit (pkgs) lib;

  supervisionPath = lib.makeBinPath [
    activateHomeManagerUsers
    stopUserTrees
    pkgs.execline
    pkgs.s6
    pkgs.s6-linux-init
    pkgs.s6-portable-utils
    pkgs.s6-rc
  ];

in
{
  # s6-linux-init-maker creates FIFOs, so this must run in the image's
  # fakeroot phase rather than in an ordinary Nix store derivation.
  installInitTreeCommands = ''
    init_tree="etc/s6-linux-init/current"
    rm -rf "$init_tree"
    ${pkgs.s6-linux-init}/bin/s6-linux-init-maker \
      -C -N -B \
      -c /etc/s6-linux-init/current \
      -s /run/s6-linux-init-env \
      -p ${lib.escapeShellArg supervisionPath} \
      -f ${./skeleton} \
      "$init_tree"

    # Some OCI layer builders omit FIFOs. Keep that packaging workaround
    # internal to the generated init boundary instead of exposing a command.
    mv "$init_tree/bin/init" "$init_tree/bin/exec-s6-linux-init"
    cat > "$init_tree/bin/init" <<'EOF'
    #!/bin/sh
    set -eu

    shutdown_command_fifo=/etc/s6-linux-init/current/run-image/service/s6-linux-init-shutdownd/fifo
    if [ -e "$shutdown_command_fifo" ] || [ -L "$shutdown_command_fifo" ]; then
      if [ ! -p "$shutdown_command_fifo" ]; then
        printf '%s\n' "s6 init: expected a FIFO: $shutdown_command_fifo" >&2
        exit 100
      fi
      chmod 0600 "$shutdown_command_fifo"
    else
      mkfifo -m 0600 "$shutdown_command_fifo"
    fi

    exec /etc/s6-linux-init/current/bin/exec-s6-linux-init "$@"
    EOF
    chmod 0755 "$init_tree/bin/init"

    nix_daemon_service_dir="$init_tree/run-image/service/nix-daemon"
    mkdir -p "$nix_daemon_service_dir"
    cat > "$nix_daemon_service_dir/run" <<'EOF'
    #!/bin/sh
    exec ${pkgs.s6}/bin/s6-envdir -I /run/s6-linux-init-env ${pkgs.nix}/bin/nix-daemon
    EOF
    chmod 0755 "$nix_daemon_service_dir/run"
  '';

  packages = [
    pkgs.execline
    pkgs.s6
    pkgs.s6-linux-init
    pkgs.s6-portable-utils
    pkgs.s6-rc
  ];
}
