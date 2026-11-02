# Testing

Run `nix flake check -L`. All checks are under `checks.x86_64-linux`.

* `unit`: descriptor schema, leaf/file-directory collisions, priorities,
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
They run the flake checks, including both QEMU suites. Local validation does not
claim a GitHub Actions run: the new repository has not been published yet.
