{
  sources ? import ./npins,
}:
{
  pkgs,
  ...
}:
{
  imports = [ (import "${sources.nix-supervise}/modules/home-manager.nix") ];

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
}
