{ pkgs, ... }:
{
  imageName = "system-image";

  exposedPorts = [ ];

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
}
