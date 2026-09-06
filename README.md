# nix-container

![Project Status: alpha](https://img.shields.io/badge/status-alpha-orange)

> [!WARNING]
> This project is experimental and alpha-quality.

`nix-container` is a template for building mutable, multi-user Linux
environments as OCI (Docker, etc.) images.

The important difference from a conventional container image is that the
system is not frozen at build time. Inside a running container:

- a root-owned system configuration declares accounts, system packages, and
  services, and can be rebuilt and applied without replacing the image;
- each declared user has a declarative [Nix](https://nix.dev/) configuration,
  applied by [Home Manager](https://github.com/nix-community/home-manager),
  that determines the packages and settings in their environment; and
- both configurations can declare long-running services, which
  [`nix-supervise`](https://github.com/ToxicPine/nix-supervise#declaring-services-and-supervision-policy)
  starts and supervises.

The environment can therefore change at runtime and survive container
replacement: `/data` holds accounts, homes, and configuration, while `/nix`
holds packages installed or built in the running container.

## Template layout

Clone this repository, customize the following files, and build it to produce
your own image:

| Path | Customize here |
| --- | --- |
| `fs/nix/system.nix` | Packages, accounts, services, image name, and exposed ports |
| `fs/nix/home-manager.nix` | The Home Manager component: user trees and activation policy |
| `fs/hm-base/` | Home Manager defaults shared by every user |
| `fs/hm-user/<name>/` | Initial packages and services for a declared user |
| `fs/skel/.nixcfg/` | Initial Home Manager config for users without one |
| `fs/bin/` | `refresh-system` and `reset-system` |
| `fs/overlay.nix` | Additional or overridden Nix packages |
| `lib/` | Image, scaffold, account, and supervision machinery |

Content under `fs/` becomes the working tree at `/opt/app` and the read-only
factory snapshot at `/opt/defaults`.

## Usage

### Configure the system

[`fs/nix/system.nix`](fs/nix/system.nix) is an overlay in the style of SixOS,
written with Infuse. It declares components, each contributing packages,
users, groups, services, and image files:

```nix
{ infuse, ... }:
final: prev:
infuse prev {
  components.local.__init = {
    packages = [ final.pkgs.ripgrep final.pkgs.rsync ];
    services.metrics.process.argv = [
      "${final.pkgs.python3}/bin/python" "-m" "http.server" "9100"
    ];
  };
  components.home-manager.__init = final.callComponent ./home-manager.nix {
    users = {
      alice.uid = 1000;
      bob = { uid = 1001; rebuildOnBoot = true; };
    };
  };
  image.exposedPorts.__append = [ 9100 ];
}
```

Because the configuration is the only source of accounts, any user or group it
does not declare is removed on the next apply, although homes are retained and
passwords, which live in `/data/etc`, survive updates. The
[composition contract](docs/COMPOSITION.md) documents the complete API.

Give a user an initial Home Manager configuration at
`fs/hm-user/<name>/home.nix`. Services use the `nix-supervise` service schema:

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
service tree. Home Manager boot behavior is set on the component or per user:

| Option | Meaning |
| --- | --- |
| `rebuildOnBoot` | Rebuild and activate the user's persistent `~/.nixcfg` on every boot. |
| `activateOnBoot` | When `rebuildOnBoot` is off, activate the existing generation on boot. A user with no generation is built once. |
| `buildProfiles` | Set in `lib/overlays/home-manager`: prebuild profiles into the image for declared users that have an `fs/hm-user/<name>/home.nix`. |

Rebuilding includes activation, so `activateOnBoot` has no effect while
`rebuildOnBoot` is enabled; the template defaults to rebuilding off and
activation on, so that boot never has to evaluate a user's configuration.

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

Both volumes are required. Because the account database lives on the data
volume rather than in the image, `docker exec --user` must be given numeric
IDs rather than names.

### Reuse a read-only host Nix store

See [Upper/lower Nix store](docs/UPPER_LOWER.md) to reuse the host's
read-only Nix store beneath a container-specific writable store.

### Change the running system

The image contains a factory generation, and at boot the container applies
the root profile in `/nix/var/nix/profiles/system` when one exists and that
factory generation otherwise, without evaluating any Nix. To change the
system, root edits the persistent copy of the configuration and applies it:

```sh
$EDITOR /data/system/nixcfg/system.nix   # for example, users.carol.uid = 1002
refresh-system
```

This builds a new generation, records it in the root profile, and updates the
live tree, which here means creating Carol's account, seeding her `~/.nixcfg`,
starting her service tree, and activating Home Manager. Removing the
declaration again stops her tree and removes the account while keeping the
home. Note that changes to accounts or packages restart every user tree,
whereas a change that only touches services updates those services alone.

Each user's live configuration is stored in `~/.nixcfg`. The user can change
packages, settings, and `supervision.services`, then apply the result:

```sh
$EDITOR ~/.nixcfg/home.nix
refresh-system
```

Home Manager builds the new generation and `nix-supervise` reconciles its
services. Adding, removing, or changing a service declaration starts, stops, or
updates the corresponding supervised process without rebuilding the image.

Use `reset-system` to restore the factory configuration from `/opt/defaults`:
as root it resets the system configuration, and with `SYSTEM_IMAGE_USER=<name>`
it resets that user's Home Manager configuration instead.

A failed build changes nothing, whereas a failed apply leaves the new
generation selected and may have applied it only partially; in either case,
fix the configuration and refresh again. To see what is currently up in the
root tree, run `s6-rc -l /run/nix-supervise/system/live -a list`.

## Runtime model

| Path | Role |
| --- | --- |
| `/data` | Persistent accounts, homes, user and system configuration, service state, and logs |
| `/nix` | Persistent Nix store, database, root profile, and Home Manager generations |
| `/nix-base` | Read-only image seed used to initialize an empty `/nix` |
| `/opt/defaults` | Read-only factory configuration from `fs/` |
| `/opt/app` | Per-container working tree; user and system configs link into `/data` |
| `/run` | Disposable sockets, live S6 state, and the selected `/run/current-system` |
