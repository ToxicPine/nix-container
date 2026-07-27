{
  description = "Equivalent nginx startup benchmark for nix-container and NixOS microVMs";

  outputs =
    { self }:
    let
      system = "x86_64-linux";
      npins = import ./fs/hm-base/npins;
      pkgs = import npins.nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
      lib = pkgs.lib;
      nixosSystem = import "${npins.nixpkgs}/nixos/lib/eval-config.nix";
      containerImage = import ./nix {
        inherit system;
        sources = npins;
      };
      snixDepot = import npins.snix { localSystem = system; };
      snixCli = snixDepot.snix.cli.make-cli {
        pname = "fast-vms-benchmark";
        paths = [
          snixDepot.snix.cli.nix-daemon
          snixDepot.snix.cli.store
        ];
        base = snixDepot.snix.cli.base;
      };

      vm = nixosSystem {
        inherit system;
        inherit pkgs;
        modules = [ ./bench/configuration.nix ];
      };

      vmKernelParams = lib.concatStringsSep " " (
        (lib.filter (
          param: param != "root=fstab" && !(lib.hasPrefix "root=" param)
        ) vm.config.boot.kernelParams)
        ++ [
          "root=LABEL=bench-root"
          "rootfstype=ext4"
          "rw"
          "init=${vm.config.system.build.toplevel}/init"
        ]
      );

      vmArtifacts = pkgs.runCommand "fast-vms-benchmark-image" { } ''
        mkdir -p "$out"
        ln -s \
          ${vm.config.system.build.image}/${vm.config.image.filePath} \
          "$out/disk.raw"
        ln -s \
          ${vm.config.system.build.kernel}/${vm.config.system.boot.loader.kernelFile} \
          "$out/kernel"
        ln -s \
          ${vm.config.system.build.initialRamdisk}/${vm.config.system.boot.loader.initrdFile} \
          "$out/initrd"
        printf '%s\n' ${lib.escapeShellArg vmKernelParams} > "$out/kernel-params"
      '';

      prepareVm = pkgs.writeShellApplication {
        name = "prepare-vm";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.qemu_kvm
        ];
        text = builtins.replaceStrings [ "@VM_ARTIFACTS@" ] [ "${vmArtifacts}" ] (
          builtins.readFile ./bench/prepare-vm.sh
        );
      };

      runVm = pkgs.writeShellApplication {
        name = "run-vm";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.qemu_kvm
        ];
        text = builtins.readFile ./bench/run-vm.sh;
      };

      runContainer = pkgs.writeShellApplication {
        name = "run-container";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.gvisor
          pkgs.jq
          pkgs.util-linux
        ];
        text = builtins.readFile ./bench/run-container.sh;
      };

      monotonicNs = pkgs.runCommandCC "monotonic-ns" { } ''
        mkdir -p "$out/bin"
        "$CC" \
          -std=c11 \
          -D_POSIX_C_SOURCE=200809L \
          -O2 \
          -Wall \
          -Wextra \
          -Werror \
          ${./bench/monotonic-ns.c} \
          -o "$out/bin/monotonic-ns"
        "$CC" \
          -std=c11 \
          -D_POSIX_C_SOURCE=200809L \
          -O2 \
          -Wall \
          -Wextra \
          -Werror \
          ${./bench/cgroup-exec.c} \
          -o "$out/bin/cgroup-exec"
      '';

      densityLoad = pkgs.runCommand "density-load" { nativeBuildInputs = [ pkgs.go ]; } ''
        export CGO_ENABLED=0
        export GOCACHE="$TMPDIR/go-cache"
        go test \
          ${./bench/density-load.go} \
          ${./bench/density-load_test.go}
        mkdir -p "$out/bin"
        go build \
          -trimpath \
          -ldflags='-s -w' \
          -o "$out/bin/density-load" \
          ${./bench/density-load.go}
      '';

      prepareBenchmarkAssets = pkgs.writeShellApplication {
        name = "prepare-benchmark-assets";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.findutils
          pkgs.gnused
          pkgs.jq
          pkgs.nix
          pkgs.umoci
        ];
        text =
          builtins.replaceStrings
            [
              "@CONTAINER_COPY@"
              "@NPINS_SOURCES@"
              "@SNIX_BIN@"
              "@VM_ARTIFACTS@"
            ]
            [
              "${containerImage.copyTo}"
              "${./fs/hm-base/npins/sources.json}"
              (lib.getExe' snixCli "snix")
              "${vmArtifacts}"
            ]
            (builtins.readFile ./bench/prepare-benchmark-assets.sh);
      };

      runSnixPlatform = pkgs.writeShellApplication {
        name = "run-snix-platform";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.fuse3
          pkgs.util-linux
        ];
        text = builtins.replaceStrings [ "@SNIX_BIN@" ] [ (lib.getExe' snixCli "snix") ] (
          builtins.readFile ./bench/run-snix-platform.sh
        );
      };

      manageBenchmarkNetwork = pkgs.writeShellApplication {
        name = "manage-benchmark-network";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.iproute2
          pkgs.jq
        ];
        text = builtins.readFile ./bench/manage-benchmark-network.sh;
      };

      manageContainerStore = pkgs.writeShellApplication {
        name = "manage-container-store";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.util-linux
        ];
        text = builtins.readFile ./bench/manage-container-store.sh;
      };

      prepareContainerInstance = pkgs.writeShellApplication {
        name = "prepare-container-instance";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.curl
          pkgs.gvisor
          pkgs.jq
          pkgs.util-linux
        ];
        text =
          builtins.replaceStrings
            [
              "@MANAGE_NETWORK@"
              "@RUN_CONTAINER@"
              "@RUN_SNIX@"
              "@RUNSC@"
            ]
            [
              (lib.getExe manageBenchmarkNetwork)
              (lib.getExe runContainer)
              (lib.getExe runSnixPlatform)
              "${pkgs.gvisor}/bin/runsc"
            ]
            (builtins.readFile ./bench/prepare-container-instance.sh);
      };

      makeBenchmarkNetworkSpec = pkgs.writeShellApplication {
        name = "make-benchmark-network-spec";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.jq
        ];
        text = builtins.readFile ./bench/make-benchmark-network-spec.sh;
      };

      prepareBenchmarkPool = pkgs.writeShellApplication {
        name = "prepare-benchmark-pool";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.jq
          pkgs.util-linux
        ];
        text =
          builtins.replaceStrings
            [
              "@MANAGE_NETWORK@"
              "@PREPARE_CONTAINER@"
              "@PREPARE_VM@"
              "@RUN_SNIX@"
            ]
            [
              (lib.getExe manageBenchmarkNetwork)
              (lib.getExe prepareContainerInstance)
              (lib.getExe prepareVm)
              (lib.getExe runSnixPlatform)
            ]
            (builtins.readFile ./bench/prepare-benchmark-pool.sh);
      };

      evictBenchmarkWorkingSet = pkgs.writeShellApplication {
        name = "evict-benchmark-working-set";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.jq
          pkgs.util-linux
          pkgs.vmtouch
        ];
        text = builtins.readFile ./bench/evict-benchmark-working-set.sh;
      };

      evictPrivateCache = pkgs.writeShellApplication {
        name = "evict-private-cache";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.vmtouch
        ];
        text = builtins.readFile ./bench/evict-private-cache.sh;
      };

      warmBenchmarkInstance = pkgs.writeShellApplication {
        name = "warm-benchmark-instance";
        runtimeInputs = [
          monotonicNs
          pkgs.coreutils
          pkgs.curl
          pkgs.gawk
          pkgs.jq
          pkgs.util-linux
        ];
        text = builtins.readFile ./bench/warm-benchmark-instance.sh;
      };

      makeBenchmarkManifest = pkgs.writeShellApplication {
        name = "make-benchmark-manifest";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.gvisor
          pkgs.jq
        ];
        text =
          builtins.replaceStrings
            [
              "@EVICT_WORKING_SET@"
              "@EVICT_PRIVATE_CACHE@"
              "@MANAGE_NETWORK@"
              "@MANAGE_STORE@"
              "@RUN_CONTAINER@"
              "@RUN_SNIX@"
              "@RUN_VM@"
              "@RUNSC@"
              "@WARM_INSTANCE@"
            ]
            [
              (lib.getExe evictBenchmarkWorkingSet)
              (lib.getExe evictPrivateCache)
              (lib.getExe manageBenchmarkNetwork)
              (lib.getExe manageContainerStore)
              (lib.getExe runContainer)
              (lib.getExe runSnixPlatform)
              (lib.getExe runVm)
              "${pkgs.gvisor}/bin/runsc"
              (lib.getExe warmBenchmarkInstance)
            ]
            (builtins.readFile ./bench/make-benchmark-manifest.sh);
      };

      prepareBenchmark = pkgs.writeShellApplication {
        name = "prepare-benchmark";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.jq
        ];
        text =
          builtins.replaceStrings
            [
              "@MAKE_MANIFEST@"
              "@MAKE_NETWORK@"
              "@PREPARE_ASSETS@"
              "@PREPARE_POOL@"
            ]
            [
              (lib.getExe makeBenchmarkManifest)
              (lib.getExe makeBenchmarkNetworkSpec)
              (lib.getExe prepareBenchmarkAssets)
              (lib.getExe prepareBenchmarkPool)
            ]
            (builtins.readFile ./bench/prepare-benchmark.sh);
      };

      prepareDensityPilot = pkgs.writeShellApplication {
        name = "prepare-density-pilot";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.jq
        ];
        text =
          builtins.replaceStrings
            [
              "@MAKE_MANIFEST@"
              "@MAKE_NETWORK@"
              "@PREPARE_ASSETS@"
              "@PREPARE_POOL@"
            ]
            [
              (lib.getExe makeBenchmarkManifest)
              (lib.getExe makeBenchmarkNetworkSpec)
              (lib.getExe prepareBenchmarkAssets)
              (lib.getExe prepareBenchmarkPool)
            ]
            (builtins.readFile ./bench/prepare-density-pilot.sh);
      };

      sizeBenchmarkPools = pkgs.writeShellApplication {
        name = "size-benchmark-pools";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.jq
        ];
        text = builtins.readFile ./bench/size-benchmark-pools.sh;
      };

      densityBatchingTest = pkgs.writeShellApplication {
        name = "density-batching-test";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.gnused
          pkgs.jq
        ];
        text =
          builtins.replaceStrings [ "@DENSITY_BATCHING@" ] [ (builtins.readFile ./bench/density-batching.sh) ]
            (builtins.readFile ./bench/density-batching-test.sh);
      };

      densityBatchingCheck = pkgs.runCommand "density-batching-check" { } ''
        ${lib.getExe densityBatchingTest} > "$out"
      '';

      runBenchmark = pkgs.writeShellApplication {
        name = "run-benchmark";
        runtimeInputs = [
          densityLoad
          monotonicNs
          pkgs.coreutils
          pkgs.curl
          pkgs.diffutils
          pkgs.findutils
          pkgs.gawk
          pkgs.gitMinimal
          pkgs.glibc.bin
          pkgs.gnused
          pkgs.jq
          pkgs.oha
          pkgs.procps
          pkgs.util-linux
          pkgs.vmtouch
        ];
        text =
          builtins.replaceStrings
            [
              "@BENCHMARK_REVISION@"
              "@BENCHMARK_SOURCE@"
              "@DENSITY_BATCHING@"
            ]
            [
              (self.rev or self.dirtyRev or "uncommitted")
              "${self}"
              (builtins.readFile ./bench/density-batching.sh)
            ]
            (builtins.readFile ./bench/run-benchmark.sh);
      };

      prepareBenchmarkCgroups = pkgs.writeShellApplication {
        name = "prepare-benchmark-cgroups";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.gawk
          pkgs.util-linux
        ];
        text = builtins.readFile ./bench/prepare-benchmark-cgroups.sh;
      };

      prepareBenchmarkHost = pkgs.writeShellApplication {
        name = "prepare-benchmark-host";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.gawk
          pkgs.jq
          pkgs.systemd
          pkgs.util-linux
        ];
        text = builtins.readFile ./bench/prepare-benchmark-host.sh;
      };

      summarizeBenchmark = pkgs.writeShellApplication {
        name = "summarize-benchmark";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.jq
        ];
        text = builtins.readFile ./bench/summarize-benchmark.sh;
      };

      summarizeBenchmarkStorage = pkgs.writeShellApplication {
        name = "summarize-benchmark-storage";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.findutils
          pkgs.gawk
          pkgs.jq
        ];
        text = builtins.readFile ./bench/summarize-benchmark-storage.sh;
      };

      runPairedBenchmark = pkgs.writeShellApplication {
        name = "run-paired-benchmark";
        runtimeInputs = [
          runBenchmark
          summarizeBenchmark
          pkgs.coreutils
          pkgs.findutils
          pkgs.jq
        ];
        text = builtins.readFile ./bench/run-paired-benchmark.sh;
      };

      runCoreBenchmark = pkgs.writeShellApplication {
        name = "run-core-benchmark";
        runtimeInputs = [
          pkgs.coreutils
        ];
        text =
          builtins.replaceStrings
            [
              "@CGROUP_EXEC@"
              "@PREPARE_CGROUPS@"
              "@PREPARE_HOST@"
              "@RUN_PAIRED@"
            ]
            [
              "${monotonicNs}/bin/cgroup-exec"
              (lib.getExe prepareBenchmarkCgroups)
              (lib.getExe prepareBenchmarkHost)
              (lib.getExe runPairedBenchmark)
            ]
            (builtins.readFile ./bench/run-core-benchmark.sh);
      };

    in
    {
      nixosConfigurations.bench-vm = vm;

      packages.${system} = {
        default = vmArtifacts;
        benchmark-helpers = monotonicNs;
        container-copy = containerImage.copyTo;
        density-load = densityLoad;
        evict-benchmark-working-set = evictBenchmarkWorkingSet;
        evict-private-cache = evictPrivateCache;
        make-benchmark-manifest = makeBenchmarkManifest;
        make-benchmark-network-spec = makeBenchmarkNetworkSpec;
        manage-benchmark-network = manageBenchmarkNetwork;
        manage-container-store = manageContainerStore;
        prepare-benchmark-assets = prepareBenchmarkAssets;
        prepare-benchmark = prepareBenchmark;
        prepare-benchmark-pool = prepareBenchmarkPool;
        prepare-density-pilot = prepareDensityPilot;
        prepare-container-instance = prepareContainerInstance;
        vm-image = vmArtifacts;
        prepare-vm = prepareVm;
        prepare-benchmark-cgroups = prepareBenchmarkCgroups;
        prepare-benchmark-host = prepareBenchmarkHost;
        run-benchmark = runBenchmark;
        run-core-benchmark = runCoreBenchmark;
        run-paired-benchmark = runPairedBenchmark;
        run-snix-platform = runSnixPlatform;
        run-vm = runVm;
        run-container = runContainer;
        size-benchmark-pools = sizeBenchmarkPools;
        summarize-benchmark = summarizeBenchmark;
        summarize-benchmark-storage = summarizeBenchmarkStorage;
        snix = snixCli;
        warm-benchmark-instance = warmBenchmarkInstance;
      };

      apps.${system} = {
        prepare-vm = {
          type = "app";
          program = lib.getExe prepareVm;
        };
        prepare-benchmark-assets = {
          type = "app";
          program = lib.getExe prepareBenchmarkAssets;
        };
        prepare-benchmark = {
          type = "app";
          program = lib.getExe prepareBenchmark;
        };
        prepare-density-pilot = {
          type = "app";
          program = lib.getExe prepareDensityPilot;
        };
        manage-benchmark-network = {
          type = "app";
          program = lib.getExe manageBenchmarkNetwork;
        };
        manage-container-store = {
          type = "app";
          program = lib.getExe manageContainerStore;
        };
        prepare-container-instance = {
          type = "app";
          program = lib.getExe prepareContainerInstance;
        };
        evict-benchmark-working-set = {
          type = "app";
          program = lib.getExe evictBenchmarkWorkingSet;
        };
        make-benchmark-manifest = {
          type = "app";
          program = lib.getExe makeBenchmarkManifest;
        };
        make-benchmark-network-spec = {
          type = "app";
          program = lib.getExe makeBenchmarkNetworkSpec;
        };
        prepare-benchmark-pool = {
          type = "app";
          program = lib.getExe prepareBenchmarkPool;
        };
        prepare-benchmark-cgroups = {
          type = "app";
          program = lib.getExe prepareBenchmarkCgroups;
        };
        prepare-benchmark-host = {
          type = "app";
          program = lib.getExe prepareBenchmarkHost;
        };
        run-vm = {
          type = "app";
          program = lib.getExe runVm;
        };
        run-container = {
          type = "app";
          program = lib.getExe runContainer;
        };
        run-benchmark = {
          type = "app";
          program = lib.getExe runBenchmark;
        };
        run-core-benchmark = {
          type = "app";
          program = lib.getExe runCoreBenchmark;
        };
        run-paired-benchmark = {
          type = "app";
          program = lib.getExe runPairedBenchmark;
        };
        run-snix-platform = {
          type = "app";
          program = lib.getExe runSnixPlatform;
        };
        size-benchmark-pools = {
          type = "app";
          program = lib.getExe sizeBenchmarkPools;
        };
        summarize-benchmark = {
          type = "app";
          program = lib.getExe summarizeBenchmark;
        };
        summarize-benchmark-storage = {
          type = "app";
          program = lib.getExe summarizeBenchmarkStorage;
        };
        warm-benchmark-instance = {
          type = "app";
          program = lib.getExe warmBenchmarkInstance;
        };
      };

      checks.${system} = {
        inherit
          densityBatchingCheck
          prepareVm
          densityLoad
          prepareBenchmark
          prepareBenchmarkAssets
          prepareBenchmarkPool
          prepareDensityPilot
          prepareContainerInstance
          prepareBenchmarkCgroups
          prepareBenchmarkHost
          runContainer
          runCoreBenchmark
          runSnixPlatform
          runPairedBenchmark
          runVm
          runBenchmark
          sizeBenchmarkPools
          summarizeBenchmark
          summarizeBenchmarkStorage
          manageBenchmarkNetwork
          manageContainerStore
          makeBenchmarkManifest
          makeBenchmarkNetworkSpec
          evictBenchmarkWorkingSet
          evictPrivateCache
          warmBenchmarkInstance
          vmArtifacts
          ;
      };

      formatter.${system} = pkgs.nixfmt-tree;
    };
}
