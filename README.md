# steamify-pacman-repo

A pacman repository for the packages Steamify installs on its own (today: [steamify-gamescope-nvidia](https://github.com/theupriser/steamify-gamescope-nvidia)),
so that they update with the system (`pacman -Syu`, Discover) and do not need Steamify to do it.

Nothing is built here. A workflow (`sync`, hourly and by hand) copies the newest release of each repository in `sources.txt`
into the release tagged `repo` of this repository, adds it to the database of its CPU variant and signs both with the key in
`steamify-pacman-repo.pub.asc` (fingerprint in `KEY_FINGERPRINT`).

## Use

One repository per CPU variant, because every variant is the same package at the same version (`generic`, `v3`, `v4`, `znver4`;
Steamify picks the best one for the PC). As root, once:

    pacman-key --add steamify-pacman-repo.pub.asc
    pacman-key --lsign-key $(cat KEY_FINGERPRINT)

and in `/etc/pacman.conf`, **below** CachyOS's own repositories (so this one never replaces a package from them):

    [steamify-v3]
    SigLevel = Required DatabaseRequired
    Server = https://github.com/theupriser/steamify-pacman-repo/releases/download/repo

Then `pacman -Sy steamify-gamescope-nvidia`.

## Add a package

Add `<GitHub repo> <package name>` to `sources.txt`. That repository's releases must carry
`<package>-<version>-<variant>.pkg.tar.zst` and a `.sha256` for each variant, as steamify-gamescope-nvidia's do.

## Setup of this repository

Secret `GPG_PRIVATE_KEY`: the armored private key of `KEY_FINGERPRINT` (no passphrase). The workflow refuses to run with another key.
