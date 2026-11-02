# Impurifier target inventory

This inventory incorporates the supplied “Comprehensive Linux Package Managers
List.pdf” and the subsequent Portage/BitBake discussion. It is a planning map,
not a claim that every listed tool is current or compatible. Package-manager
implementations and lifecycle behavior must be verified with primary sources
and VM tests before a target is supported.

The useful boundary is the native artifact/metadata contract and its lifecycle,
not a distribution name or every command-line frontend. Distributions primarily
supply runtime packages whose dependency names/behavior consumers choose.

## Native package-manager backends

| Backend | Coverage to investigate | Status |
| --- | --- | --- |
| dpkg-impurifier | DEB/dpkg, with apt transactions | Implemented; unit/emitter checks and two VM suites |
| rpm-impurifier | RPM; dnf, zypper and other RPM frontends | Implemented with RPM/systemd VM coverage; dnf/zypper frontend behavior needs explicit tests |
| pacman-impurifier | ALPM packages and hooks | Implemented with pacman/systemd VM coverage |
| apk-impurifier | APK metadata and triggers | Implemented with Alpine APK/OpenRC VM coverage |
| portage-impurifier | Ebuild/eclass overlay, native binpkgs | Candidate; emerge batching is an open design question |
| opkg-impurifier | IPK/opkg | Candidate; distinct from APK/apk |
| xbps-impurifier | XBPS artifacts and lifecycle | Candidate |
| pkgtools-impurifier | Slackware packages and install/remove behavior | Candidate; verify wrapper-specific semantics |
| eopkg-impurifier / pisi-impurifier | Native artifacts and metadata | Candidate; establish actual shared-format boundary |
| pkgutils-impurifier | CRUX package tools and ports recipes | Candidate |
| kiss-impurifier / cpt-impurifier | Source recipes and native package ownership | Candidate; do not assume fork compatibility |
| sorcery-impurifier / lunar-impurifier | Spells/modules and lifecycle | Candidate; separate investigation required |
| pkgsrc-impurifier | Package recipes and native binary artifacts | Candidate |

APT interfaces such as aptitude or synaptic do not automatically require another
artifact compiler. Neither do AUR helpers merely because they invoke pacman.
Likewise the different RPM frontends do not automatically imply separate
impurifiers. They do expand the integration-test matrix where behavior differs.

Portage alternatives (Paludis/pkgcore), Entropy, historical ipkg/autopackage,
Tiny Core extensions, and Puppy packages remain research candidates from the
inventory. Shared lineage or similar filenames do not establish compatibility.

## Recipe and image construction

`bitbake-impurifier` is the candidate name for emitting recipes/classes, initially
**BitBake targeting OpenEmbedded/Yocto**. BitBake is the task execution engine;
OpenEmbedded supplies the packaging/image metadata; Yocto is the wider project.
It is not another runtime package-manager backend. RPM/DEB/IPK integration can
be reused below it when appropriate. Image-time closure/profile construction
must also work without assuming a mutable target or running target binaries on
the build host.

rpm-ostree, transactional-update, bootc, systemd-sysext and swupd introduce image,
snapshot or extension lifecycle contracts. Evaluate them as separate activation
adapters: ordinary runtime maintainer scripts cannot be assumed to work during
image construction or across a reboot/snapshot boundary. Bedrock is an
integration environment for other package managers rather than an obvious new
artifact format.

## Other possible output ecosystems

Flatpak, Snap, AppImage and Zero Install are potential bundle/sandbox output
adapters. They need their own execution/closure-path integration and may not
provide the native OS ownership goal of the first backends. Homebrew, Spack and
Conda-family outputs are also possible recipe/environment adapters. None is
claimed supported by the native-package implementation.

Nix and Guix are not excluded by terminology, but an output adapter needs a
concrete interoperability benefit; wrapping one functional store inside another
is not itself a useful feature.

## Cross-cutting work

A native **Nix provider/installer** remains deferred but in scope. We and users
should be able to provide Nix through an impure package. Its bootstrap,
coexistence, daemon integration, upgrades and offline installation require a
separate pristine-host VM matrix. Current impurifiers expose consumer-controlled
native dependency expressions so this provider does not require redesigning
application packaging.

New backends must establish their own transaction/error/recovery semantics.
Share the validated engine/descriptor/cache mechanisms when extracting a common
core, but do not claim dpkg's awaited-trigger behavior for other managers.
