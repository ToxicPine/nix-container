# nix-container

![Project Status: alpha](https://img.shields.io/badge/status-alpha-orange)

> [!WARNING]
> This project is experimental and alpha-quality.

`nix-container` is a template for building mutable, multi-user Linux
environments as OCI (Docker, etc.) images.

The important difference from a conventional container image is that the set
of users and services is not frozen at build time. Inside a running container:

- the system configuration manages declared accounts, while standard account
  tools can manage additional persistent users;
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
| `fs/nix/system.nix` | Packages, system components, accounts, image name and ports |
| `fs/nix/home-manager.nix` | Runtime Home Manager accounts and supervision services |
| `lib/modules/home-manager/` | Build-only HM hooks, factory configuration placement and profiles |
| `fs/hm-base/` | Home Manager defaults shared by every managed user |
| `fs/hm-user/<name>/` | Initial packages and services for a declared user |
| `fs/skel/.nixcfg/` | Initial Home Manager config for users added at runtime |
| `fs/overlay.nix` | Additional or overridden Nix packages |
| `lib/` | Image, persistence, account, and supervision machinery |

Content under `fs/` becomes the working tree at `/opt/app` and the read-only
factory snapshot at `/opt/defaults`.

## Usage

### Compose the system

[`fs/nix/system.nix`](fs/nix/system.nix) is a SixOS-style overlay using
upstream Infuse. It selects ordinary Nix components, whose contributions feed
both the system generation and the OCI image:

```nix
{ infuse, ... }:
final: prev:
infuse prev {
  components.local.__init = {
    image.order = 10;
    packages = [ final.pkgs.ripgrep final.pkgs.rsync ];
  };
  components.home-manager.__init = final.callComponent ./home-manager.nix {
    users = {
      alice.uid = 1000;
      bob = { uid = 1001; rebuildOnBoot = true; };
    };
    rebuildOnBoot = false;
    activateOnBoot = true;
  };
  components.metrics.__init = {
    packages = [ final.pkgs.python3 ];
    services.metrics.process.argv = [
      "${final.pkgs.python3}/bin/python" "-m" "http.server" "9100"
    ];
  };
  image.exposedPorts.__append = [ 9100 ];
}
```

Components can contribute packages, users, groups, services, and image files
and directories. Account hooks are baked into the image. Infuse overlays can override their
constructor inputs or the resulting declarations. See the
[composition contract](docs/COMPOSITION.md) for the complete API, layering,
resource ownership, and update semantics.

The wrapper realizes accounts and resources before starting dependent
services. Home Manager contributes an account creation hook, a supervised user
tree, activation, and optional prebuilt profiles in its own image layer.
`rebuildOnBoot` includes activation; otherwise `activateOnBoot` activates an
existing or factory profile, building once if neither exists. These defaults
can be overridden per user. The build-only overlay in
`lib/modules/home-manager` controls `buildProfiles` and factory configuration
placement; `nix/default.nix` applies it after the system configuration.

Users' Home Manager configurations still use ordinary Home Manager modules:

```nix
{ pkgs, ... }:
{
  imports = [ (import ../../hm-base { }) ];
  home.packages = [ pkgs.python3 ];
  supervision.services.web.process.argv = [
    "${pkgs.python3}/bin/python" "-m" "http.server" "8080"
  ];
}
```

The image contains a factory generation. At boot, the root profile in
`/nix/var/nix/profiles/system` is selected if available, otherwise the factory
generation. Boot applies that saved generation without evaluating Nix. Run
`refresh-system` as root to build and apply changes to the persistent
`system.nix`; subsequent boots use the saved result.

Build failure and activation failure are different:

| Failure | Result |
| --- | --- |
| Root evaluation/build | Refresh returns failure without changing the profile or live system. |
| Root application | Returns failure; the new root profile stays selected. Services and resources may be partially changed; there is no automatic rollback. Resource failure prevents its dependent services from starting. |
| HM evaluation/build | Existing profile and home remain untouched. With HM `rebuildOnBoot = true`, the apply oneshot fails without activating the old profile, so user services may remain down on a fresh boot. |
| HM activation | Checks such as file-collision detection run before the write boundary. After that boundary, the profile may already select the new generation and files, packages or services may be partially changed. There is no automatic rollback. |

These are retryable, non-transactional activations. Retaining the selected service
set after an activation failure avoids removing unrelated services through a
factory fallback. Fix the configuration or resource conflict and run
`refresh-system` again. Old generations remain available for deliberate recovery;
switching a profile alone does not undo mutable data changes or apply services.
For HM boot availability without evaluating configuration, use `rebuildOnBoot =
false; activateOnBoot = true;` (the template defaults).

Existing configurations using the old `imports`, `users`, and `homeManager`
module interface must be converted to the overlay form above before refreshing
with this version. Existing accounts can be adopted when their declared UID
and GID match; specify `gid` when it differs from the UID.

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
$EDITOR /data/system/nixcfg/system.nix   # add users.carol.uid = 1002 to the Home Manager constructor
refresh-system
```

The rebuilt root generation creates the account, seeds `~/.nixcfg` from
`/opt/defaults/skel/.nixcfg`, starts the user's supervision tree, and
activates Home Manager. Removing the declaration and refreshing stops the tree
and its services and removes its declared account, while retaining the home
data. Passwords survive updates, but deleting an account removes its password;
recreating it starts with a locked password. Accounts created with plain `useradd` remain unmanaged.
Declared accounts are reconciled on the next resource application; UID/GID
mismatches fail explicitly instead of silently retaining a different identity.

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
using the supervision transition machinery. Resource changes currently restart
dependent services; a services-only edit retains the normal selective updates. Bumping the pins under
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
| `/run` | Disposable sockets, live S6 state, and the selected `/run/current-system` resource tree |
