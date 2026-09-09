{
  sources ? import ./npins,
}:
{
  pkgs,
  lib,
  ...
}:
{
  imports = [ (import "${sources.nix-supervise}/modules/home-manager.nix") ];

  options.supervision.services = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submoduleWith {
        modules = [ { config.s6.restartOnChange = lib.mkDefault true; } ];
      }
    );
  };

  config = {
    i18n.glibcLocales = pkgs.glibcLocalesUtf8;

    home = {
      stateVersion = "25.11";

      sessionPath = [
        "$HOME/.nix-profile/bin"
        "$HOME/.local/state/nix/profiles/home-manager/home-path/bin"
      ];

      sessionVariables = {
        NIX_REMOTE = "daemon";
      };

    };

    programs.home-manager.enable = true;

    systemd.user.enable = false;
  };
}
