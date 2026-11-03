# Testing

Run `nix flake check -L`. All checks are under `checks.x86_64-linux`.

* `unit`: shared-core contracts for descriptor schema, leaf/file-directory collisions, priorities,
  symlink cycles, and safe pruning.
* `emitter`: invalid author declarations, custom native Nix dependency
  expressions, versioned virtual Provides, and absence of application closure
  references from net artifacts.
* `vm`: QEMU guest with real dpkg, Nix, systemd, sysusers, tmpfiles and a writable
  store. Covers missing substitution and recovery, offline imports with the
  network disabled, batching, conffiles, flavor switching, cache substitution,
  upgrades, collision failures, priorities, concurrent reconciliation, GC roots,
  service lifecycle, unit-only upgrades, recovery after a failed restart,
  administrator stop/disable decisions, removal and pruning.
* `vm-debian`: QEMU guest containing the pinned official Debian 13 rootfs in a
  chroot. Runs Debian's actual apt, dpkg and package database to test virtual
  dependencies, offline installation, provider switching, conffiles and purge.

Both VMs allow QEMU software emulation when KVM is unavailable. The native
userspace test supplies preinstalled Nix/Python from the surrounding VM; it is
not a test of installing Nix, booting a complete Debian system, or Debian's
systemd as PID 1. The systemd test uses a NixOS PID 1 and deliberately exposes a
mutable native-style unit directory. Neither is a substitute for the deferred
installer's pristine-host matrix.

Application closures are imported from the built offline artifacts. Test inputs
are copied out of the store before destructive guest GC, so GC cannot keep an
application alive merely because the host built its artifact. The service test
caught a published-generation permission bug invisible to root-only CLI tests.

Focused runs:

```sh
nix build '.#checks.x86_64-linux.vm' -L --no-link
nix build '.#checks.x86_64-linux.vm-debian' -L --no-link
```

## CI

The three cached-check workflows follow the workspace pipeline, copied from
ch-zsh-config at `138f31451af4896f3a6259af397db990fb2fb9a7` with VM-specific
prose/timeouts and cache uploads disabled. They require no cache upload secrets.
They run all flake checks, including the systemd, Debian userspace, SDK producer
and six frontend QEMU suites. Concurrent Nix builds are limited to two. The public repository runs these checks on GitHub Actions. Each new revision
still requires local native checks and its own CI evidence.

The engine/payload/cache implementation is now in the pinned `impurifier` source
input. Changing that dependency is gated by both VM suites, including the
service-restart recovery regression. The backend preserves its original state
and cache namespace when invoking the shared engine.

Lifecycle migrations and native host-library upgrades are checked in backend VMs. Hardware fixtures use a real ELF loader and versioned native driver packages; dpkg additionally checks service restart, immutable old generations, missing-library failure and snapshot GC roots. Real GPU compatibility requires separate device testing.

The frontend suites and SDK provenance are documented in
[debian-frontends.md](debian-frontends.md). Aptitude's automatic runtime removal
is a regression gate: the runtime prerm must clear projected intent and release
retained roots while its engine and dependencies still exist. Every frontend
also exercises an explicit runtime purge when its solver retains the runtime.

`vm-native` installs native-owned closure DEBs into an isolated official Debian
13 userspace inside QEMU, without binding the surrounding VM's store or supplying
Nix. It checks execution, two applications sharing dependencies, upgrade,
automatic dependency retention/removal, native checksums, and absence of Nix's
executable/database/socket. This is a userspace installation test, not a complete
Debian boot.

`vm-bundled` installs a static Nix executable into an isolated Debian userspace with its own Debian Python runtime. It checks local-store import and
execution without a daemon, preference for an external client, bundled fallback,
and package removal. `tests/static-nix.nix` fixes a missing syscall header in the
pinned static Nix fixture without changing the ecosystem's nixpkgs pin.
