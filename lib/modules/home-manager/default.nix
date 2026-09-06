# Build-only Home Manager integration. This overlay is never copied into /opt.
# Configure image policy here, then supply the returned overlay to nix-base.
{
  buildProfiles ? true,
  factoryConfigDir ? ../../../fs/hm-user,
}:
{
  pkgs,
  lib,
  sources,
  infuse,
  ...
}:
final: prev:
let
  nixSupervisePackages = pkgs.callPackages "${sources.nix-supervise}/pkgs" { };
  users = final.components.home-manager.users;
  hooks = pkgs.runCommand "home-manager-account-hooks" { } ''
    mkdir -p "$out"
    substitute ${./hooks/useradd-post} "$out/useradd-post" \
      --replace-fail '@runtimeShell@' '${pkgs.runtimeShell}' \
      --replace-fail '@coreutils@' '${pkgs.coreutils}' \
      --replace-fail '@findutils@' '${pkgs.findutils}' \
      --replace-fail '@gawk@' '${pkgs.gawk}'
    substitute ${./hooks/userdel-post} "$out/userdel-post" \
      --replace-fail '@runtimeShell@' '${pkgs.runtimeShell}' \
      --replace-fail '@rm@' '${pkgs.coreutils}/bin/rm'
    substitute ${./hooks/userdel-pre} "$out/userdel-pre" \
      --replace-fail '@runtimeShell@' '${pkgs.runtimeShell}' \
      --replace-fail '@jq@' '${pkgs.jq}/bin/jq' \
      --replace-fail '@s6rc@' '${nixSupervisePackages.s6Rc}/bin/s6-rc'
    chmod 0755 "$out/"*
    ${pkgs.shellcheck}/bin/shellcheck --enable=all --severity=style "$out/"*
  '';
  factoryGenerations = lib.optionalAttrs buildProfiles (
    lib.mapAttrs (
      name: _:
      ((import sources.home-manager { inherit pkgs; }).lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          (factoryConfigDir + "/${name}/home.nix")
          {
            home.username = name;
            home.homeDirectory = "/home/${name}";
          }
        ];
      }).activationPackage
    ) (lib.filterAttrs (name: _: builtins.pathExists (factoryConfigDir + "/${name}/home.nix")) users)
  );
  image = {
    order = 50;
    files = {
      "/etc/shadow-maint/useradd-post.d/60-home-manager" = "${hooks}/useradd-post";
      "/etc/shadow-maint/userdel-pre.d/50-home-manager-services" = "${hooks}/userdel-pre";
      "/etc/shadow-maint/userdel-post.d/50-home-manager" = "${hooks}/userdel-post";
    };
    storePaths = lib.attrValues factoryGenerations;
    trees =
      lib.mapAttrs' (
        name: _: lib.nameValuePair "/opt/defaults/hm-user/${name}" (factoryConfigDir + "/${name}")
      ) (lib.filterAttrs (name: _: builtins.pathExists (factoryConfigDir + "/${name}")) users)
      // lib.optionalAttrs (factoryGenerations != { }) {
        "/opt/defaults/home-manager-generations" = pkgs.linkFarm "home-manager-factory-generations" (
          lib.mapAttrsToList (name: path: { inherit name path; }) factoryGenerations
        );
      };
  };
in
if !(prev.components ? home-manager) || !(prev.components.home-manager.enable or true) then
  { }
else
  infuse prev {
    components.home-manager.image.__init = image;
  }
