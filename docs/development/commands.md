# Commands

```sh
nix flake check -L
nix build '.#runtime-deb' '.#hello-net-deb' '.#hello-offline-deb'
nix fmt
```

See [testing](testing.md) for focused VM invocations and coverage boundaries.
