{
  config,
  lib,
  modulesPath,
  pkgs,
  ...
}:

let
  benchmarkData = import ../fs/benchmark-data.nix { inherit pkgs; };
  nginxConfig = pkgs.writeText "benchmark-nginx.conf" (
    builtins.replaceStrings [ "@BENCHMARK_1M@" ] [ "${benchmarkData}" ] (
      builtins.readFile ../fs/nginx.conf
    )
  );
  configureBenchmarkNetwork = pkgs.writeShellApplication {
    name = "configure-benchmark-network";
    runtimeInputs = [ pkgs.iproute2 ];
    text = ''
      address=10.0.2.15/24
      read -r -a kernel_parameters < /proc/cmdline

      for parameter in "''${kernel_parameters[@]}"; do
        case "''${parameter}" in
          benchmark.ip=*)
            address=''${parameter#benchmark.ip=}
            ;;
        esac
      done

      ip link set dev eth0 up
      ip address flush dev eth0 scope global
      ip address add "''${address}" dev eth0
    '';
  };
in
{
  imports = [
    "${modulesPath}/image/repart.nix"
    "${modulesPath}/profiles/minimal.nix"
  ];

  system.stateVersion = "26.05";
  system.image.id = "fast-vms-benchmark";

  image.repart = {
    name = "fast-vms-benchmark";
    compression.enable = false;
    seed = "8e10d432-52ad-4b1e-83a5-3d7cf86fbc17";
    partitions."10-root" = {
      storePaths = [ config.system.build.toplevel ];
      repartConfig = {
        Type = "root-x86-64";
        Format = "ext4";
        Label = "bench-root";
        Minimize = "guess";
        SizeMinBytes = "1G";
      };
    };
  };

  fileSystems."/" = {
    device = "/dev/disk/by-label/bench-root";
    fsType = "ext4";
    options = [ "noatime" ];
  };

  boot = {
    blacklistedKernelModules = [ "kvm_amd" ];
    kernelModules = [ "virtio_balloon" ];
    loader.grub.enable = false;
    initrd = {
      checkJournalingFS = false;
      includeDefaultModules = false;
      systemd.enable = false;
      availableKernelModules = [
        "ext4"
        "virtio_blk"
        "virtio_mmio"
      ];
    };
    kernelParams = [
      "loglevel=3"
      "quiet"
      "reboot=t"
      "systemd.show_status=auto"
    ];
  };

  networking = {
    hostName = "bench-vm";
    useDHCP = false;
    usePredictableInterfaceNames = false;
    firewall.enable = false;
  };

  systemd = {
    services.benchmark-network = {
      description = "Configure deterministic benchmark networking";
      wantedBy = [ "multi-user.target" ];
      before = [ "benchmark-nginx.service" ];
      bindsTo = [ "sys-subsystem-net-devices-eth0.device" ];
      after = [ "sys-subsystem-net-devices-eth0.device" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe configureBenchmarkNetwork;
      };
    };

    services.benchmark-nginx = {
      description = "Equivalent fast-vms nginx benchmark workload";
      wantedBy = [ "multi-user.target" ];
      requires = [ "benchmark-network.service" ];
      after = [
        "benchmark-network.service"
        "local-fs.target"
      ];
      serviceConfig = {
        Type = "exec";
        ExecStart = "${pkgs.nginx}/bin/nginx -c ${nginxConfig} -g 'daemon off;'";
        Restart = "no";
      };
    };

    services."serial-getty@hvc0".enable = false;
    services."serial-getty@ttyS0".enable = false;
    services.systemd-growfs-root.enable = false;
    services."getty@tty1".enable = false;

  };

  services = {
    dbus.enable = lib.mkForce false;
    journald = {
      storage = "volatile";
      extraConfig = ''
        RuntimeMaxUse=8M
        ForwardToConsole=no
      '';
    };
    nscd.enable = false;
    logind.enable = false;
    timesyncd.enable = false;
    udisks2.enable = false;
  };

  systemd.oomd.enable = false;
  system.nssModules = lib.mkForce [ ];

  nix = {
    channel.enable = false;
    gc.automatic = false;
    optimise.automatic = false;
    settings = {
      auto-optimise-store = false;
      experimental-features = [
        "nix-command"
        "flakes"
      ];
    };
  };

  security = {
    audit.enable = false;
    sudo.enable = false;
  };

  console.enable = false;
  programs.command-not-found.enable = false;

  documentation = {
    enable = false;
    doc.enable = false;
    info.enable = false;
    man.enable = false;
    nixos.enable = false;
  };

  environment = {
    defaultPackages = lib.mkForce [ ];
    systemPackages = [ ];
  };

  users = {
    allowNoPasswordLogin = true;
    manageLingering = false;
    mutableUsers = false;
    users.user = {
      isNormalUser = true;
      uid = 1000;
    };
  };
}
