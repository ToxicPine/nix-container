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
| `nix/default.nix` | First-boot users and Home Manager policy |
| `nix/system.nix` | Image name, base packages, and exposed ports |
| `fs/hm-base/` | Home Manager defaults shared by every managed user |
| `fs/hm-user/<name>/` | Initial packages and services for a declared user |
| `fs/skel/.nixcfg/` | Initial Home Manager config for users added at runtime |
| `fs/overlay.nix` | Additional or overridden Nix packages |
| `lib/` | Image, persistence, account, and supervision machinery |

Content under `fs/` becomes the working tree at `/opt/app` and the read-only
factory snapshot at `/opt/defaults`.

## Usage

### Configure users and services

Use `declaredUsers` in [`nix/default.nix`](nix/default.nix) to seed the initial
accounts when the container first starts with a fresh `/data` volume. This is
not a fixed list of allowed users: standard Linux account tools can add,
modify, and remove users at runtime.

```nix
declaredUsers = {
  alice.uid = 1000;
  bob.uid = 1001;
};
```

After initialization, the account database in `/data/etc` is authoritative.
Changing `declaredUsers` affects new volumes; it does not overwrite the users
in an existing deployment.

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
service tree. Changing the declaration later and running `refresh-system`
updates the running tree.

Home Manager boot behavior is also configured in `nix/default.nix`:

```nix
hmPolicy = {
  buildProfiles = true;
  activateOnBoot = true;
  rebuildOnBoot = true;
};
```

| Option | Meaning |
| --- | --- |
| `buildProfiles` | Prebuild profiles into the image for declared users that have an `fs/hm-user/<name>/home.nix`. This does not apply to users added later. |
| `rebuildOnBoot` | Rebuild and activate each managed user's persistent `~/.nixcfg` on every boot. |
| `activateOnBoot` | When `rebuildOnBoot` is off, activate the existing generation on boot. A newly managed user with no generation is built once. |

Rebuilding includes activation, so `activateOnBoot` has no effect while
`rebuildOnBoot` is enabled.

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

### Change the running system

Account changes use the normal Linux tools and persist in `/data/etc`:

```sh
useradd --create-home --uid 1002 carol
```

To give a runtime-created user the template's Home Manager configuration:

```sh
seed-user-hm carol
```

The new user's Home Manager profile and service tree are discovered on the next
boot. Users without a profile remain ordinary Linux users.

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

## Runtime model

| Path | Role |
| --- | --- |
| `/data` | Persistent accounts, homes, user configuration, service state, and logs |
| `/nix` | Persistent Nix store, database, and Home Manager generations |
| `/nix-base` | Read-only image seed used to initialize an empty `/nix` |
| `/opt/defaults` | Read-only factory configuration from `fs/` |
| `/opt/app` | Per-container working tree; user configs link into `/data` |
| `/run` | Disposable sockets and live S6 state |
