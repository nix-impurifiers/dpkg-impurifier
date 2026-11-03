# Native Debian frontend fixtures

The frontend SDK producer starts with the same official Debian 13 rootfs used
by the existing Debian VM. It installs real Aptitude, Nala, gdebi-core, Synaptic,
Xvfb and their dependencies using native apt/dpkg while external networking is
disabled. It exports the resulting userspace and actual package database for
consumer VMs. The image's original policy-rc.d suppresses starting services in
the chroot; it does not replace any frontend implementation.

`tests/debian-sdk-packages.json` records package URLs, exact versions, sizes and
SHA-256 hashes from the signed Debian snapshot at
`https://snapshot.debian.org/archive/debian/20261102T000000Z`, suite `trixie`,
component `main`, architecture `amd64`. The dependency set was resolved by native
APT against the official base image's real installed-package status. GnuPG
verified InRelease using that image's Debian archive keyring before hashes were
read from its package index. Fixed-output Nix fetches check each SHA-256 again.

Index provenance:

- InRelease SHA-256: `0584fba32e13e0ab8285fb16c27adea1ec03a73669c18702821094fd6ca86675`
- Uncompressed Packages SHA-256: `4f2c68d67001d595fbd343f6dbad44468953a51c4d9dec3a4803249f6e295940`

The producer's offline package installation honors native dependencies and
scriptlets. It does not use fake provider packages, force dependency checks off,
or install packages on the developer's host. The consumer fixture's Nix
provider owns a link to the actual preinstalled Nix executable. Python and the
frontend stack are genuine Debian packages from the snapshot.

Consumer tests use NixOS as PID 1 and the exported Debian userspace in a chroot.
They do not claim complete Debian boot or desktop-session coverage. Synaptic
uses a real Xvfb server for its noninteractive transaction interface. GDebi is
an installer; native apt performs removal in its tests.

The consumer's local repository is produced by native dpkg-scanpackages and
apt-ftparchive and signed by GnuPG. Each VM changes the clearsigned InRelease
text, observes native signature rejection and verifies that the cached trusted
index remains unchanged. APT may return success while retaining its last good
index; tests check the signature diagnostic and index bytes rather than assuming
that every failed refresh has a nonzero exit code.

The VM harness launches terminal-sensitive frontends in a fresh session with
foreground timeouts and a clean Debian environment. Otherwise terminal job-control
signals can stop them in the test driver's background session. Native frontend
code is unchanged. GDebi's unattended configuration test selects force-confold
through native dpkg configuration. Synaptic still opens its real conffile dialog:
an X11 observer activates the native Keep button and records that interaction.
It uses the native set-selections-file and closeZvt options under Xvfb. This is
GUI transaction coverage, not a test of a full desktop session.
