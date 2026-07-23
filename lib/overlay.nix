{ pkgs }:

final: _prev:

let
  provision-user-home = pkgs.callPackage ./pkgs/provision-user-home { };
in
{
  nix-store-bootstrap-diff = final.callPackage ./pkgs/nix-store-bootstrap-diff { };
  nss-altfiles = pkgs.callPackage ./pkgs/nss-altfiles { };
  inherit provision-user-home;
  seed-user-hm = pkgs.callPackage ./pkgs/seed-user-hm { inherit provision-user-home; };

  shadow =
    (pkgs.shadow.override {
      pam = null;
      withLibbsd = false;
      withTcb = false;
    }).overrideAttrs
      (old: {
        configureFlags = (old.configureFlags or [ ]) ++ [
          "shadow_cv_maildir=none"
          "shadow_cv_mailfile=none"
        ];
        patches = (old.patches or [ ]) ++ [ ./patches/shadow-account-data-paths.patch ];
      });

  util-linuxMinimal = pkgs.util-linuxMinimal.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./patches/util-linux-account-data-paths.patch ];
  });
}
