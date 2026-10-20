# Arch cloud-image trust anchor

`arch-boxes.asc` is the release public key published in the **Releases** section
of the official [archlinux/arch-boxes README], retrieved on 2026-10-20.

- Primary key: `1B9A16984A4E8CB448712D2AE0B78BF4326C6F8F`
- Signing subkey: `656E4C5AC1CC3B86E539D97E343635A6859A9174`
- Identity: `arch-boxes <arch-boxes@archlinux.org>`

This is a separate image-release key, not a package-maintainer key supplied by
`archlinux-keyring`. The VM harness uses an isolated keyring containing only
this pinned certificate. No key is selected from an untrusted signature or
downloaded dynamically from a keyserver. A key rotation requires reviewing the
official source and updating this file. Official kernel packages continue to
use the Arch package keyring and Pacman verification.

[archlinux/arch-boxes README]: https://github.com/archlinux/arch-boxes#releases
