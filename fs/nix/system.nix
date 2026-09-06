# Infuse can change either their inputs (__input) or their resulting fields.
{ infuse, ... }:
final: prev:
let
  pkgs = final.pkgs;

  local = {
    image.order = 10;
    packages = [
      pkgs.bzip2
      pkgs.diffutils
      pkgs.file
      pkgs.findutils
      pkgs.gawk
      pkgs.gnugrep
      pkgs.gnused
      pkgs.gnutar
      pkgs.gzip
      pkgs.inetutils
      pkgs.less
      pkgs.ncurses
      pkgs.openssl
      pkgs.simplified.procps
      pkgs.psmisc
      pkgs.ripgrep
      pkgs.rsync
      pkgs.tree
      pkgs.unzip
      pkgs.which
      pkgs.xz
      pkgs.zip
    ];

    # services.metrics.process.argv = [
    #   "${pkgs.python3}/bin/python" "-m" "http.server" "9100"
    # ];
    # image.files."/etc/example.conf" = pkgs.writeText "example.conf" "hello\n";
  };

  homeManager = final.callComponent ./home-manager.nix {
    users.user.uid = 1000;
    rebuildOnBoot = false;
    activateOnBoot = true;
  };
  # Without Infuse, the expression after `in` would be:
  #
  # assert !(prev.components ? local);
  # assert !(prev.components ? home-manager);
  # prev // {
  #   components = prev.components // {
  #     inherit local;
  #     home-manager = homeManager;
  #   };
  # }
  #
  # The assertions preserve __init's refusal to replace an existing component.
  # Both // operations are needed because plain Nix merges attribute sets shallowly.
in
infuse prev {
  components.local.__init = local;
  components.home-manager.__init = homeManager;

  # To expose the example service's port, also add:
  # image.exposedPorts.__append = [ 9100 ];
  # Its plain-Nix equivalent, inside the outer `prev // { ... }`, is:
  # image = prev.image // {
  #   exposedPorts = prev.image.exposedPorts ++ [ 9100 ];
  # };
}
