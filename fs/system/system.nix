# Root configuration: the users this image provides on first boot and the
# services of the root supervision tree. Everything here is a declaration the
# root tree realizes, and `refresh-system` as root applies edits to this file.
{ pkgs, ... }:
{
  imports = [ ./home-manager.nix ];

  # Accounts created on a fresh /data volume. A user with Home Manager
  # enabled gets ~/.nixcfg seeded from /opt/defaults/hm-user/<name> (or the
  # skeleton), a supervision tree, and activation on boot. Add users here at
  # runtime too, then run refresh-system as root.
  users.user = {
    uid = 1000;
    homeManager.enable = true;
  };

  homeManager = {
    rebuildOnBoot = false;
    activateOnBoot = true;
    buildProfiles = true;
  };

  # Additional root-level services. They use the same service schema as user
  # services and may pick an execution user.
  # supervision.system.services.metrics = {
  #   process.argv = [ "${pkgs.python3}/bin/python" "-m" "http.server" "9100" ];
  #   s6.execution.user = "nobody";
  # };
}
