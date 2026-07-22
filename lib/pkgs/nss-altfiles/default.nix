{
  fetchurl,
  lib,
  stdenv,
}:

stdenv.mkDerivation {
  pname = "nss-altfiles";
  version = "2.43.0";

  src = fetchurl {
    url = "https://github.com/flatcar/nss-altfiles/archive/refs/tags/v2.43.0.tar.gz";
    hash = "sha256-Oso+Fj6K2ZvrVLeyG5HXVRy4FVJqxrOh37c00F84cYc=";
  };

  configureFlags = [
    "--datadir=/data/etc"
    "--with-types=pwd,grp,initgroups,spwd,sgrp"
  ];

  meta = {
    description = "NSS module for account files outside /etc";
    homepage = "https://github.com/flatcar/nss-altfiles";
    license = lib.licenses.lgpl21Plus;
    platforms = lib.platforms.linux;
  };
}
