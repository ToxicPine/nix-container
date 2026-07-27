{ pkgs, ... }:

let
  benchmarkData = import ../../benchmark-data.nix { inherit pkgs; };
  nginxConfig = pkgs.writeText "benchmark-nginx.conf" (
    builtins.replaceStrings [ "@BENCHMARK_1M@" ] [ "${benchmarkData}" ] (
      builtins.readFile ../../nginx.conf
    )
  );
in
{
  supervision.services.nginx.process.argv = [
    "${pkgs.nginx}/bin/nginx"
    "-c"
    nginxConfig
    "-g"
    "daemon off;"
  ];
}
