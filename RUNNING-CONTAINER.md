# Preparing and launching the gVisor target

Status: July 2026. Store and OCI preparation are setup work and must finish
before a benchmark interval. `nix run .#run-container` only validates and
launches an already-prepared bundle.

## Build the benchmark image

The branch uses `localOverlayStore = "socket"` and bakes the `user` Home
Manager generation into the image. `rebuildOnBoot = false` prevents evaluating
and rebuilding the Home Manager configuration during launch. Normal first-use
activation can still construct the mutable per-user Nix profile around that
baked generation; complete that initialization while preparing each instance,
then preserve its private upper, `/data`, and `/nix` together for measured
launches.

```sh
nix-build nix -A copyToDockerDaemon -o result-docker
./result-docker/bin/copy-to-docker-daemon
```

Convert/unpack that image into one OCI runtime bundle per container using the
OCI tooling used by the benchmark host. Each bundle must have its own rootfs
and `config.json`; set the process args to the image entrypoint and expose port
8080 through the pre-created network namespace or host forwarding. Network
namespace and forwarding setup are not part of timed launch.

## Shared Snix lower store

Keep Snix state outside the host Nix installation and start both services from
the same backends:

```sh
SNIX_ROOT=/var/lib/fast-vms/snix
mkdir -p "$SNIX_ROOT/castore/blobs" "$SNIX_ROOT/store" /run/fast-vms/snix

BLOB_SERVICE_ADDR="objectstore+file:$SNIX_ROOT/castore/blobs" \
DIRECTORY_SERVICE_ADDR="redb:$SNIX_ROOT/castore/directories.redb" \
PATH_INFO_SERVICE_ADDR="redb:$SNIX_ROOT/store/pathinfo.redb" \
snix store daemon -l /run/fast-vms/snix/store.sock

BLOB_SERVICE_ADDR="grpc+unix:/run/fast-vms/snix/store.sock" \
DIRECTORY_SERVICE_ADDR="grpc+unix:/run/fast-vms/snix/store.sock" \
PATH_INFO_SERVICE_ADDR="grpc+unix:/run/fast-vms/snix/store.sock" \
snix store mount --allow-other /srv/snix-store

BLOB_SERVICE_ADDR="grpc+unix:/run/fast-vms/snix/store.sock" \
DIRECTORY_SERVICE_ADDR="grpc+unix:/run/fast-vms/snix/store.sock" \
PATH_INFO_SERVICE_ADDR="grpc+unix:/run/fast-vms/snix/store.sock" \
snix nix-daemon \
  -l /run/fast-vms/snix/socket \
  --unix-listen-unlink \
  --unix-listen-chmod everybody
```

`--allow-other` requires `user_allow_other` in `/etc/fuse.conf` (on NixOS,
`programs.fuse.userAllowOther = true`). Populate and verify the lower store
before the benchmark. The mounted files and daemon metadata must describe the
same immutable paths.

## Per-instance state

Create a distinct upper, work, merged mount, data directory, and Nix directory
for every instance:

```sh
INSTANCE_ROOT=/var/lib/fast-vms/containers/alpha
mkdir -p \
  "$INSTANCE_ROOT/upper" \
  "$INSTANCE_ROOT/work" \
  "$INSTANCE_ROOT/merged" \
  "$INSTANCE_ROOT/data" \
  "$INSTANCE_ROOT/nix"

mount -t overlay overlay \
  -o "lowerdir=/srv/snix-store,upperdir=$INSTANCE_ROOT/upper,workdir=$INSTANCE_ROOT/work" \
  "$INSTANCE_ROOT/merged"
```

The upper and work directories must be on the same filesystem. Never share an
upper, `/data`, or `/nix` directory between instances. The private upper and
private `/nix` database form one persistent unit and must be reset, moved, or
backed up together.

Add these mounts to each bundle's `config.json`, after the `/nix` mount where
applicable:

```json
{
  "mounts": [
    {
      "destination": "/run",
      "source": "tmpfs",
      "type": "tmpfs",
      "options": ["nosuid", "nodev", "mode=755", "size=16777216"]
    },
    {
      "destination": "/data",
      "source": "/var/lib/fast-vms/containers/alpha/data",
      "type": "bind",
      "options": ["rbind", "rw", "nosuid", "nodev"]
    },
    {
      "destination": "/nix",
      "source": "/var/lib/fast-vms/containers/alpha/nix",
      "type": "bind",
      "options": ["rbind", "rw", "nosuid", "nodev"]
    },
    {
      "destination": "/nix/store",
      "source": "/var/lib/fast-vms/containers/alpha/merged",
      "type": "bind",
      "options": ["rbind", "rw", "nosuid", "nodev"]
    },
    {
      "destination": "/lower-store",
      "source": "/run/fast-vms/snix",
      "type": "bind",
      "options": ["rbind", "ro", "nosuid", "nodev", "noexec"]
    }
  ]
}
```

Do not put `noexec` on `/nix/store`. Mount the Snix socket's directory rather
than the socket, so a daemon restart can replace it.
The private `/run` tmpfs is required because the image deliberately treats
runtime state as volatile and ships the underlying directory non-writable.
Its size is a ceiling, not preallocated memory.

Boot every instance once during setup so account data, the private Nix
database, and the user's normal Home Manager/Nix profiles are initialized.
Stop it cleanly, then keep its `/data`, `/nix`, and private upper unchanged as
one prepared unit for the experiment.

## Launch flags

The flake's launcher executes:

```sh
runsc \
  --platform=kvm \
  --directfs=true \
  --overlay2=root:self \
  --file-access-mounts=exclusive \
  --host-uds=open \
  --ignore-cgroups=true \
  run --bundle BUNDLE CONTAINER_ID
```

Directfs avoids a Gofer RPC for each filesystem operation. The rootfs overlay
keeps container-root writes in runsc's efficient private internal overlay;
the unpacked OCI rootfs remains an unmodified shared lower. Do not recursively
remove its write permission bits: those bits are container filesystem metadata,
and changing them prevents the deliberately capability-minimized PID 1 from
using normal writable directories such as `/run`.
`file-access-mounts=exclusive` permits directory-entry caching because every
mutable bind mount has exactly one sandbox owner and the lower is immutable.
`host-uds=open` permits connection to the already-mounted read-only Snix
daemon socket; the narrower `open` policy does not permit the sandbox to create
host sockets.
`ignore-cgroups` avoids redundant runtime cgroup setup: put the launcher in its
already-created benchmark cgroup before invocation, and the Sentry and Gofer
inherit that placement. Include the complete inherited cgroup in resource
accounting.
Do not modify an instance's bind-mounted state from the host while it runs.

Useful references are [gVisor Directfs](https://gvisor.dev/blog/2023/06/27/directfs/),
[gVisor rootfs overlay](https://gvisor.dev/blog/2023/05/08/rootfs-overlay/),
and [Snix local-overlay guidance](https://snix.dev/docs/guides/local-overlay/).
