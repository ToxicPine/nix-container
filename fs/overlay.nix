_final: prev:

{
  simplified = prev.lib.makeScope prev.newScope (_: {
    procps = prev.procps.override {
      withSystemd = false;
    };

    tmux = prev.tmux.override {
      withSystemd = false;
    };

    openssh = prev.openssh.override {
      withPAM = false;
      withSecurityKey = false;
    };

  });
}
