# nix-container

![Project Status: alpha](https://img.shields.io/badge/status-alpha-orange)

> [!WARNING]
> This project is experimental and alpha-quality.

`nix-container` is a template for building mutable, multi-user Linux
environments as OCI (Docker, etc.) images.

The important difference from a conventional container image is that the set
of users and services is not frozen at build time. Inside a running container:

- standard account tools can add, modify, and remove persistent users;
- each managed user has a declarative [Nix](https://nix.dev/) configuration,
  applied by [Home Manager](https://github.com/nix-community/home-manager),
  that determines the packages and settings in their environment; and
- the same configuration can declare long-running services, which
  [`nix-supervise`](https://github.com/ToxicPine/nix-supervise#declaring-services-and-supervision-policy)
  starts and supervises.

The environment can therefore change at runtime and survive container
replacement: `/data` holds users, homes, and configuration, while `/nix` holds
packages installed or built in the running container.

## Template layout

Clone this repository, customize the following files, and build it to produce
your own image:

| Path | Customize here |
| --- | --- |
| `nix/image.nix` | Image name, base packages, and exposed ports |
| `fs/system/` | First-boot users, Home Manager boot policy, and root-level services |
| `fs/system/home-manager.nix` | Home Manager as a root-tree module: seeding, user trees, activation |
| `fs/hm-base/` | Home Manager defaults shared by every managed user |
| `fs/hm-user/<name>/` | Initial packages and services for a declared user |
| `fs/skel/.nixcfg/` | Initial Home Manager config for users added at runtime |
| `fs/overlay.nix` | Additional or overridden Nix packages |
| `lib/` | Image, persistence, account, and supervision machinery |

Content under `fs/` becomes the working tree at `/opt/app` and the read-only
factory snapshot at `/opt/defaults`.

## Usage

### Configure users and services

Declare the initial users in [`fs/system/system.nix`](fs/system/system.nix).
Each one is created on first boot with a fresh `/data` volume. This is not a
fixed list of allowed users: standard Linux account tools can add, modify, and
remove users at runtime.

```nix
users = {
  alice = {
    uid = 1000;
    homeManager.enable = true;
  };
  bob.uid = 1001;
};
```

After initialization, the account database in `/data/etc` is authoritative.
Changing the declarations affects new volumes; existing accounts are kept as
they are.

A user with `homeManager.enable` gets `~/.nixcfg` seeded from
`fs/hm-user/<name>/` (or from `fs/skel/.nixcfg/` when there is no such
directory), a supervised service tree, and Home Manager activation on boot.
Services use the `nix-supervise` service schema:

```nix
{ pkgs, ... }:
{
  imports = [ (import ../../hm-base { }) ];

  home.packages = [ pkgs.python3 ];

  supervision.services.web.process.argv = [
    "${pkgs.python3}/bin/python"
    "-m"
    "http.server"
    "8080"
  ];
}
```

This profile installs Python for Alice and boots `web` in her supervised
service tree. Changing the declaration later and running `refresh-system`
updates the running tree.

Home Manager boot behavior is configured in the same file, for all users or
per user:

```nix
homeManager = {
  rebuildOnBoot = true;
  activateOnBoot = true;
};
users.bob.homeManager.rebuildOnBoot = false;
```

| Option | Meaning |
| --- | --- |
| `rebuildOnBoot` | Rebuild and activate the user's persistent `~/.nixcfg` on every boot. |
| `activateOnBoot` | When `rebuildOnBoot` is off, activate the existing generation on boot. A user with no generation yet is built once. |
| `buildProfiles` | Prebuild the generations of declared users that have an `fs/hm-user/<name>/home.nix` into the image, so first boot activates without building. Users added later are built on first activation. |

Rebuilding includes activation, so `activateOnBoot` has no effect while
`rebuildOnBoot` is enabled.

### Configure the root supervision tree

Everything above PID 1 is a service in one root `nix-supervise` tree. The base
provides the Nix daemon and an account for each declared user. Importing
`fs/system/home-manager.nix`, as the template does, expands each user
with Home Manager enabled into a oneshot that seeds the home, a longrun for
the user's own supervision tree, and a oneshot that activates the user's Home
Manager generation. The tree's contents come from a Nix generation, not from
the image, so root can change them at runtime.

`fs/system/system.nix` also declares additional root-level services. They use
the same service schema as user services and may select an execution user:

```nix
{ pkgs, ... }:
{
  supervision.system.services.metrics = {
    process.argv = [ "${pkgs.python3}/bin/python" "-m" "http.server" "9100" ];
    s6.execution.user = "nobody";
  };
}
```

The image bakes a factory generation from this file. At boot, the root profile
in `/nix/var/nix/profiles/system` is applied when it exists, otherwise the
factory generation. Boot never evaluates Nix for the root tree; the profile
changes only when root runs `refresh-system`. Users added to the persistent
copy of this file at runtime are created and seeded exactly like first-boot
ones.

### Build and run

The default target is `x86_64-linux` and requires a matching local or remote
Linux builder.

```sh
nix-build nix -A copyToDockerDaemon -o result-docker
./result-docker/bin/copy-to-docker-daemon

docker run --detach \
  --name system-image \
  --volume system-image-data:/data \
  --volume system-image-nix:/nix \
  --publish 8080:8080 \
  system-image:latest
```

For Podman, build `copyToPodman` instead. The generic `copyTo` target accepts
other Skopeo destinations, including OCI layouts and registries.

Both volumes are required.

### Reuse a read-only host Nix store

See [Upper/lower Nix store](docs/UPPER_LOWER.md) to reuse the host's
read-only Nix store beneath a container-specific writable store.

### Change the running system

Adding a managed user at runtime is the same declaration as at build time,
made in the persistent system configuration and applied by root:

```sh
$EDITOR /data/system/nixcfg/system.nix   # users.carol = { uid = 1002; homeManager.enable = true; };
refresh-system
```

The rebuilt root generation creates the account, seeds `~/.nixcfg` from
`/opt/defaults/skel/.nixcfg`, starts the user's supervision tree, and
activates Home Manager. Removing the declaration and refreshing stops the tree
and its services; the account and home stay until removed with `userdel`,
which also stops the tree. Accounts created with plain `useradd` remain
ordinary Linux users, and a declared account that is deleted by hand is
recreated on the next boot.

Each managed user's live configuration is stored in `~/.nixcfg`. The user can
change packages, settings, and `supervision.services`, then apply the result:

```sh
$EDITOR ~/.nixcfg/home.nix
refresh-system
```

Home Manager builds the new generation and `nix-supervise` reconciles its
services. Adding, removing, or changing a service declaration starts, stops, or
updates the corresponding supervised process without rebuilding the image.

Use `reset-system` to restore the factory configuration from `/opt/defaults`.

Root uses the same two commands for the root tree. Editing
`/data/system/nixcfg/system.nix` and running `refresh-system` as root builds a
new generation, records it in the root profile, and updates the live tree
without restarting unaffected services. Bumping the pins under
`/opt/app/hm-base/npins` and refreshing replaces the supervision toolchain the
same way: the new generation's s6 governs every user tree from its next start,
while PID 1 itself changes only with the image.

`s6-rc -l /run/nix-supervise/system/live -a list` shows what is up in the root
tree, including which Home Manager activations completed.

## Runtime model

| Path | Role |
| --- | --- |
| `/data` | Persistent accounts, homes, user and system configuration, service state, and logs |
| `/nix` | Persistent Nix store, database, root supervision profile, and Home Manager generations |
| `/nix-base` | Read-only image seed used to initialize an empty `/nix` |
| `/opt/defaults` | Read-only factory configuration from `fs/` |
| `/opt/app` | Per-container working tree; user and system configs link into `/data` |
| `/run` | Disposable sockets and live S6 state |
