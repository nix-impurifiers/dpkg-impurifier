# dpkg-impurifier

Emit native `.deb` packages whose applications live in a Nix store closure.
`dpkg` owns install intent, configuration files, users, directories and service
units. One transaction trigger reconciles the installed descriptors into
`/opt/nix/profile`. Repository: [nix-impurifiers/dpkg-impurifier](https://github.com/nix-impurifiers/dpkg-impurifier).

This impurifier targets **dpkg**, not a particular distribution. Debian and
Ubuntu can use the same artifacts when their runtime dependencies are met.
The package-manager family is `dpkg-impurifier`, `rpm-impurifier`,
`pacman-impurifier`, and `apk-impurifier`; this repository implements dpkg.

## Build

```sh
nix build '.#runtime-deb' '.#hello-net-deb' '.#hello-offline-deb'
nix flake check -L
```

The runtime package requires Python 3 and Nix. It does not install Nix itself.
Providing Nix through an impure package is **deferred, not out of scope**:
it requires a separate installer/bootstrap implementation and tests.

## Package a Nix application

The backend uses the pinned [shared impurifier core](https://github.com/nix-impurifiers/impurifier)
for its engine, payloads and closure caches. It retains its existing descriptor,
state and cache paths. The library takes the consumer's package set rather than
choosing one for them:

```nix
let
  impurifier = inputs.dpkg-impurifier.lib.dpkg-impurifier { inherit pkgs; };
  packages = impurifier.makePackage {
    pkg = pkgs.hello;
    # Optional overrides: name, version, priority (lower wins).
  };
in {
  hello-net = packages.net;
  hello-offline = packages.offline;
  runtime = impurifier.makeRuntimeDeb {
    nixDependency = "nix-bin | nix-external-runtime";
  };
}
```

`makeDeb`, `makeNetDeb`, and `makeOfflineDeb` also return individual artifacts.
`makeRuntimeDeb.nixDependency` is a native dependency expression. A consumer
can instead name their own Nix provider, including a future impurified Nix.
The runtime searches native executable directories and
`/nix/var/nix/profiles/default/bin`. No distribution detection or implicit Nix
installer runs in maintainer scripts. An externally managed Nix installation
must have a native provider/shim package that accurately declares its presence.

Install the runtime and either application flavor with `apt install ./…deb`.
Both flavors provide the logical application name and replace/conflict with
one another. Native packages can depend on a version of that virtual name.

**Net** packages carry descriptors and host integration, without retaining the
application closure as a Nix dependency. Configure trusted substituters and
signing keys in Nix before installing them. **Offline** packages carry an
entire closure as a local binary cache; their imports use only that cache,
without remote builders. Nix and Python must already be available in either
case. The native package/repository authenticates the offline payload; its
NAR hashes still verify the imported bytes. Nothing changes global cache trust.

## Host integration

```nix
impurifier.makeOfflineDeb {
  pkg = telemetryAgent;
  users.telemetry = {
    group = "telemetry";
    description = "Telemetry daemon";
    home = "/var/lib/telemetry";
  };
  directories."/var/lib/telemetry" = {
    owner = "telemetry:telemetry";
    mode = "0750";
  };
  configFiles."/etc/telemetry/config.yaml" = {
    source = ./config.yaml;
    mode = "0640";
  };
  systemd = {
    unit = ./telemetry.service; # ExecStart=/opt/nix/profile/bin/telemetry
    enable = true;
    startOnInstall = true;
    restartOnUpgrade = true;
    stopOnRemove = true;
  };
}
```

`users` generate sysusers declarations; `directories` generate tmpfiles
rules. Accounts and persistent data survive removal. Configuration files are
native conffiles, with dpkg's usual edit/upgrade/purge behavior. `files` installs
additional `/usr` assets, excluding reserved manifest/cache paths. Both file
maps accept a source directly or `{ source; mode; }` (default `0644`).

Host integration defaults to native dependencies `systemd` and
`init-system-helpers`; consumers can override `hostDependencies` to match their
repositories. The profile is ready before new services start. Upgrades restart
running services when the binary or unit changes, without starting an
administrator-stopped service or re-enabling an administrator-disabled one.
Debian's systemd helpers are used when present, including `policy-rc.d`.

## Operations and recovery

```sh
sudo nix-profile-engine reconcile
sudo nix-profile-engine status
sudo nix-profile-engine prune --keep 2
```

The engine serializes operations with a lock. It validates the entire desired
manifest set, realizes and roots closures, checks collisions, builds a fresh
symlink tree, then atomically changes the active profile link. A failed fetch
or composition leaves the previous profile active. Equal-priority collisions
fail; lower numeric priorities win for leaf files. Directory/file collisions
and directory symlink cycles fail. Only `bin`, `sbin`, `lib`, `libexec`, `share`,
and `include` are projected; host `/etc` is managed by native package files.

A service activation failure is reported to dpkg. The profile may already
have advanced; activation remains pending and is retried on reconciliation. Pending start/restart
intent survives a failed restart, so installing the repaired unit can recover it.
That retry resumes the recorded intent; an intentionally stopped service with no
pending restart stays stopped.
Filesystem, native package database, and service changes are not one atomic
transaction. The engine does not claim whole-host rollback or zero downtime.

An awaited trigger failure can leave the runtime unconfigured. Supply the
missing cache/closure and run `dpkg --configure --pending`, or let apt repair
the pending transaction. To recover with local media, unpack the offline
flavor first, then configure pending packages:

```sh
sudo dpkg --unpack ./application-offline.deb
sudo dpkg --configure --pending
```

Generation metadata and GC roots live under `/var/lib/dpkg-impurifier`.
Old generations remain rooted until explicitly pruned; pruning never removes
the active generation. Nix garbage collection remains a separate action.
Use native package downgrades to roll back install intent and host files.

See [testing](docs/development/testing.md) and
[design decisions and deferred work](docs/design.md). The broader
[targets inventory](docs/targets.md) tracks other package-manager and recipe targets.

MIT.

Lifecycle hooks `lifecycle.onInstall` and `lifecycle.onUpgrade` accept shell bodies. They run as root after accounts/directories exist and the new profile is published, before service activation. Use `/opt/nix/profile/bin/<tool>` for projected commands and declare native dependencies for other commands. Install hooks run until the application's first successful activation; upgrade hooks run when its output, version or hook revision changes, including native downgrades. A failed hook leaves activation pending and may be retried, so hooks must be idempotent. They do not provide database rollback or exactly-once execution. Flavor-only changes to the same application do not rerun completed hooks.

Host-library bridging is opt-in:

```nix
hardware = {
  libraries."libdriver.so.1" = "/usr/lib/libdriver.so.1";
  programs = [ "my-tool" ];
  preload = []; # Optional subset of declared library names.
};
```

The engine captures explicitly selected ELF files into an immutable Nix-store directory, roots it with the generation, and wraps the selected application's `bin` commands with `LD_LIBRARY_PATH` and optional `LD_PRELOAD`. Native library-directory transaction hooks reconcile driver upgrades. Changed snapshots create a new generation and restart previously running managed services according to their upgrade policy. Older generations retain their original user-space snapshot. Missing or unreadable libraries abort before profile publication; the existing snapshot remains usable.

Consumers select compatible libraries, their non-Nix dependencies, paths and native package dependencies. This does not discover a GPU stack, validate its ABI, rebind already-running processes, or roll back kernel modules. GPU user/kernel compatibility and real-device behavior need hardware tests. Sources outside `/usr/lib`, `/usr/lib64`, `/lib` and `/lib64` need explicit reconciliation after updates. This is a bounded runtime bridge, not automatic GPU compatibility.
