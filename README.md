# nix-container

![Project Status: alpha](https://img.shields.io/badge/status-alpha-orange)

> [!WARNING] This project is experimental and alpha-quality.

`nix-container` is a template for building mutable, multi-user Linux
environments as OCI (Docker, etc.) images.

`fs/` holds the initial configuration for the running system, including the Nix
expression used to rebuild it. These files are seeded into a mutable
configuration folder used at runtime.

[`lib/image.nix`](lib/image.nix) builds the image, copying `fs/` into its `/opt`
tree. It also pre-seeds Nix store content, including a prebuilt default system
generation, and can install miscellaneous system files or directories through
OCI layers. This content, such as configuration files installed under `/etc`, is
fixed at image build time.

[`nix/default.nix`](nix/default.nix) determines what `image.nix` should pre-seed
in addition to the copied `fs/` tree. It takes `fs/nix/system.nix` and composes
it with build-only overlays that declare the aforementioned fixed image content.
The result is passed to `image.nix` to create the image's OCI layers.

Inside the running container, root can edit the configuration in `/opt`, copied
from `fs/` at image build time, and run `refresh-system` to change packages,
accounts, and services.

`/data` holds accounts, homes, and persistent configuration, while `/nix` holds
the store and saved generations.

## Template layout

Clone this repository, customize the following files, and build it to produce
your own image:

| Path                | Customize here                                             |
| ------------------- | ---------------------------------------------------------- |
| `fs/`               | Seed configuration and tools for the running system        |
| `fs/nix/system.nix` | System packages, accounts, and services                    |
| `fs/bin/`           | Commands available in the running system                   |
| `fs/overlay.nix`    | Additional or overridden Nix packages                      |
| `lib/overlays/`     | Build-only extensions using the component image API        |
| `nix/default.nix`   | Compose the overlays and build the image with its defaults |
| `lib/`              | Image, persistence, account, and supervision machinery     |

### Home Manager integration

[Home Manager](https://github.com/nix-community/home-manager) is an optional
integration included in the template and an example of how runtime configuration
and build-only extensions fit together:

| Path                         | Role                                                                         |
| ---------------------------- | ---------------------------------------------------------------------------- |
| `fs/nix/home-manager.nix`    | Runtime component for managed accounts and user supervision                  |
| `fs/nix/scripts/`            | User activation script available to later generations                        |
| `fs/hm-base/`                | Shared Home Manager defaults                                                 |
| `fs/hm-user/<name>/`         | Per-user factory configuration                                               |
| `fs/skel/.nixcfg/`           | Fallback configuration for new users                                         |
| `lib/overlays/home-manager/` | Build-only account hooks, factory config installation, and profile prebuilds |

The runtime pieces live in `fs/` so they remain available to rebuild and edit.
The image overlay lives in `lib/overlays/`, which is not copied into the running
system. It uses the image API to install fixed support such as `useradd` hooks.
Composing this build-only overlay with the system configuration from `fs/` in
`nix/default.nix` is the pattern for adding integrations: runtime sources go in
`fs/`, while build-only code stays in `lib/overlays/`.

## Usage

### Configure the system

Use [`fs/nix/system.nix`](fs/nix/system.nix) to declare system-wide packages,
accounts, and services.

```nix
{ infuse, ... }:
final: prev:
infuse prev {
  components.local.__init = {
    packages = [ final.pkgs.ripgrep final.pkgs.rsync ];
    users.alice.uid = 1000;
    services.web.process.argv = [
      "${final.pkgs.python3}/bin/python" "-m" "http.server" "8080"
    ];
  };
  image.exposedPorts.__append = [ 8080 ];
}
```

### Home Manager options

Set Home Manager boot behavior on its component in `fs/nix/system.nix` or per
user:

| Option           | Meaning                                                                                                          |
| ---------------- | ---------------------------------------------------------------------------------------------------------------- |
| `rebuildOnBoot`  | Rebuild and activate the user's persistent `~/.nixcfg` on every boot.                                            |
| `activateOnBoot` | When `rebuildOnBoot` is off, activate a saved or prebuilt generation on boot. A user with neither is built once. |

Rebuilding includes activation, so `activateOnBoot` has no effect while
`rebuildOnBoot` is enabled. The template turns rebuilding off and activation on.
The image overlay prebuilds profiles for users with an
`fs/hm-user/<name>/home.nix`; set `buildProfiles = false` on its import in
`nix/default.nix` to skip that step.

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

Both volumes are required. Account names live in `/data/etc`, so use numeric IDs
with `docker exec --user`. To open a shell as Alice:

```sh
docker exec --interactive --tty --user 1000:1000 \
  --env HOME=/home/alice --env USER=alice system-image bash
```

### Reuse a read-only host Nix store

See [upper/lower Nix store](docs/UPPER_LOWER.md) to reuse the host's read-only
Nix store beneath a container-specific writable store.

### Change the running system

As root, edit the persistent system configuration and apply it:

```sh
$EDITOR /data/system/nixcfg/system.nix
refresh-system
```

For example, add `users.carol.uid = 1002;` to the Home Manager component's
arguments to create Carol's account, seed her configuration, and start her user
services.

Refresh builds a generation, records it in `/nix/var/nix/profiles/system`, and
reconciles accounts and selects packages before applying services. Account or
package changes leave unrelated services running; changes to service definitions
take effect on restart. Boot applies the saved system generation, or the image's
factory generation if none is available, without rebuilding the system
configuration.

Each Home Manager user's live configuration is stored in `~/.nixcfg`. The user
can change packages, settings, and `supervision.services`, then apply the
result:

```sh
$EDITOR ~/.nixcfg/home.nix
refresh-system
```

Home Manager builds the new generation and `nix-supervise` reconciles its
services. Adding or removing a service declaration starts or stops the
corresponding supervised process without rebuilding the image. Services default
to `s6.restartOnChange = false`; set it to `true` to restart a service when its
definition changes on refresh. Otherwise, changes take effect when it next
starts.

Use `reset-system` to restore and apply the factory configuration from
`/opt/defaults`. Run as root, it resets the system configuration; run as a
managed user, it resets that user's Home Manager configuration. Root can also
reset a user's configuration with `SYSTEM_IMAGE_USER=<name> reset-system`.

A failed build leaves the running system alone. A failed apply can leave partial
changes and the new system generation selected; correct the cause and refresh
again. See the [scaffold contract](docs/SCAFFOLD.md#failures) for recovery
details.

## Runtime model

| Path            | Role                                                                         |
| --------------- | ---------------------------------------------------------------------------- |
| `/data`         | Persistent accounts, homes, configuration, service state, and logs           |
| `/nix`          | Persistent Nix store, database, system profile, and Home Manager generations |
| `/nix-base`     | Read-only image seed used to initialize and update `/nix`                    |
| `/opt/defaults` | Read-only factory configuration                                              |
| `/opt/app`      | Per-container working tree; user and system configs link into `/data`        |
| `/run`          | Disposable sockets, live S6 state, and the selected `/run/current-system`    |
