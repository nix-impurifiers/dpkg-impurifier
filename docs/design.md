# Impurifier design

The original distro-projected-profile notes are a vision, not a compatibility
specification. The useful inversion survives: the native package manager owns
install intent and host integration; Nix owns application closures.

## Boundaries

Impurifiers align with **package managers**, not distributions:

| Project | Native interface | Repository-dependent choices |
| --- | --- | --- |
| dpkg-impurifier | `.deb`, dpkg triggers, apt solver | Nix/Python/systemd dependency names and behavior |
| rpm-impurifier | `.rpm`, RPM transaction file triggers | Nix/service dependency expressions |
| pacman-impurifier | ALPM packages and transaction hooks | Runtime providers and supervisor packages |
| apk-impurifier | APK packages and triggers | Runtime providers and OpenRC integration |
| portage-impurifier (candidate) | Ebuilds/eclasses, overlays, native binpkgs | Runtime atoms, account dependencies and verified emerge batching |
| opkg-impurifier (candidate) | IPK packages and opkg | Runtime providers and verified transaction integration |
| bitbake-impurifier (candidate) | Recipes/layers and image construction | Target architecture, image policy, build-time activation |

The organization is `nix-impurifiers`. Only the dpkg backend is implemented in
this repository. Dependency policy is supplied by consumers; no detection table
of distribution names or releases belongs in the projection engine.

## Decisions backed by executable tests

* Compose directories directly, without evaluating nixpkgs or invoking a target
  compiler. Store output paths are the descriptor contract. Do not use flakes as
  an execution-time indirection mechanism for immutable application binaries.
* Use persistent GC roots before publication. Atomic symlink replacement alone
  would not keep a profile's closures alive during Nix GC.
* Use explicit sibling `Conflicts` and `Replaces` with versioned virtual
  `Provides`. Virtual self-conflicts prevented automatic provider replacement in
  the tested dpkg flow. This differs from the proposed metadata example.
* Await the dpkg trigger so projection errors remain visible to the native
  package transaction. Failures require normal pending-package recovery, which
  is tested. Triggers coalesce work, but dpkg may process multiple trigger waves;
  content-derived generations make repeat reconciliation a no-op. Do not promise
  exactly one engine invocation in every possible transaction.
* Keep cache trust administrator-owned. A manifest cannot add trusted keys or
  remote caches. Offline package-owned caches are explicitly trusted only for
  that import. No global signature policy is weakened.
* Keep native conffiles and service policy. Do not replace native configuration
  semantics with a competing configuration-file state machine.
* Treat native audit registration as top-level inventory. It does not make all
  Nix closure dependencies visible to native vulnerability scanners, and native
  library updates do not patch those closures.

## Deferred work (still in scope)

**Providing Nix in an impure package is an installer project.** We or our users
must be able to supply that provider. The configurable native dependency is the
integration point now. The future provider must bootstrap an empty store without
needing Nix to import itself, register and root its closure, establish daemon
accounts/configuration/units where appropriate, support existing installations,
upgrades and removal, and work offline. It needs pristine-host VM tests of its
own. It must not be disguised as an already-working dependency shim.

The other package-manager backends need their own format emitters and real
package-manager VM tests. The common engine, payload compiler and closure cache are now supplied by the
pinned `nix-impurifiers/impurifier` source dependency; no maintained engine is
copied between backends. RPM uses the same core with its own native emitter and
transaction-file-trigger tests.

The hardware membrane uses explicitly selected ELF files captured into rooted, immutable Nix-store directories. Selected commands receive runtime wrappers; native library-directory triggers refresh snapshots after upgrades. A real native driver-package VM fixture verifies changed and old generations, failed capture, managed service restart and GC. This is not automatic GPU stack discovery or an ABI guarantee. Consumers must select compatible native libraries and dependencies; real-device compatibility remains separate evidence.

OpenRC is implemented in the shared core and exercised by the APK backend in an Alpine userspace VM. Install/upgrade lifecycle hooks now run through shared activation with retry semantics. Runtime installation shims, additional
architectures, native repository publishing, driver hooks, and full bare-host
bootstrap are not implemented by this first backend.

## Portage and Yocto target considerations

Portage is a direct package-manager target. Emit an overlay/eclass and ebuilds,
with optional native binary packages; keep runtime atoms consumer-configurable.
Do not assume a transaction trigger comparable to dpkg. Establish and VM-test
batching across emerge before choosing the activation mechanism. Gentoo's
account-package conventions and configuration protection need their own mapping.
See the [Gentoo dependency model](https://devmanual.gentoo.org/general-concepts/dependencies/)
and [binary package configuration](https://devmanual.gentoo.org/eclass-reference/make.conf/index.html).

Yocto/OpenEmbedded is an image/recipe integration target, with package managers
beneath it. Existing RPM/DEB backends and a future **opkg/IPK** backend can serve
runtime-managed images. IPK/opkg is distinct from APK/apk. A BitBake integration
can additionally assemble a closure/profile during image construction, including
images without runtime package management. For read-only images, activation must
finish during image construction instead of requiring a first-boot store write.
Do not assume target-architecture executables can run on the image builder.
See [Yocto package management](https://docs.yoctoproject.org/dev-manual/packages.html)
and [read-only image requirements](https://docs.yoctoproject.org/security-manual/read-only-rootfs.html).
