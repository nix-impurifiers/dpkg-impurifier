# Technology

Nix emits native packages using dpkg-deb. A Python standard-library engine calls
Nix's stable store CLI and native host integration tools. Caisson composes the
standalone flake. Consumers supply their own package set. Runtime hosts need no
Nix expression evaluator inputs or application compiler.

QEMU integration checks, including Debian's own apt/dpkg userspace, are the main
behavioral evidence. Python unit tests and Nix emitter checks cover small schema
and authoring contracts. MIT, as chosen for this project.
