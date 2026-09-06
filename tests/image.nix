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
    python3 ${./verify-image.py} ${image} ${image.imageRegistration}/store-paths ${image.factorySystemGeneration}
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
    # The HM link namespace survives removal of its old refresh expression.
    test -d ${image.rootFilesystem}/opt/app/hm-user
    test -x ${image.rootFilesystem}/opt/app/bin/refresh-system
    test ! -e ${image.rootFilesystem}/opt/app/hm-user/refresh.nix
    test ! -e ${image.rootFilesystem}/opt/app/scaffold/refresh.nix
    # Build-only HM sources are absent from both installed configuration trees.
    for prefix in app defaults; do
      test ! -e ${image.rootFilesystem}/opt/"$prefix"/nix/scripts/hooks
      test ! -e ${image.rootFilesystem}/opt/"$prefix"/overlays/home-manager
      test -f ${image.rootFilesystem}/opt/"$prefix"/nix/home-manager.nix
    done
    touch "$out"
  ''
