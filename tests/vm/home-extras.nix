# A user's runtime edit: one package and one supervised service.
{ pkgs, ... }:
{
  home.packages = [ pkgs.hello ];
  supervision.services.web.process.argv = [
    "${pkgs.python3}/bin/python"
    "-m"
    "http.server"
    "8080"
  ];
}
