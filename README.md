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

## What is in it

| Package | From | Used by |
|---|---|---|
| `steamify-gamescope-nvidia` | the newest release of [steamify-gamescope-nvidia](https://github.com/theupriser/steamify-gamescope-nvidia) (per CPU variant) | Steamify's SteamOS conversion on NVIDIA |
| `steamify-python-hid-shim` | `packages/` (any) | Steamify, on PCs that keep `python-hidapi` |
| `steamify-cros-ec-cec-dkms` | `packages/` (any): Valve's `cros-ec-cec.c` plus Steamify's single-port patch | the Steam Machine's HDMI-CEC (Steamify does not install it from here yet) |
| `steamify-leds-valve-dkms` | `packages/` (any): Valve's LED bar driver, DKMS packaging by Adam Honse, creator of [OpenRGB](https://openrgb.org) ([leds-valve-dkms](https://gitlab.com/CalcProgrammer1/leds-valve-dkms), GPL-2.0-only), copied here; replaces the AUR `leds-valve-dkms-git` | the Steam Machine's front LED bar (Steamify installs it from the AUR today) |
| `steamify-keyring` | `packages/` (any): the signing key(s) as a pacman keyring (`steamify.gpg`, `steamify-trusted`, `steamify-revoked`) | every PC that lists the repository, so key changes arrive with `pacman -Syu` |
| `steamify-fremont-poweroff-dkms` | `packages/` (any) | the Steam Machine's power-off fix (same) |
| `steamify-fancontrol-dkms` | `packages/` (any): Valve's `steamdeck` and `steamdeck_hwmon` drivers, built only for kernels that lack them (SteamOS's kernels have them); contributed by [@Toxican](https://github.com/Toxican) | the Steam Machine's fan monitoring and OS fan control (with `jupiter-fan-control`) |

Architecture-independent packages are in every variant's database.

## Special thanks

- **[@Toxican](https://github.com/Toxican)** - `steamify-fancontrol-dkms` and the Steam Machine fan monitoring and control it belongs to
  ([steamify-cachyos#140](https://github.com/theupriser/steamify-cachyos/issues/140), #141): the research on a real Fremont, the DKMS Makefile and
  `dkms.conf`, the provider handling and the tests behind it.
- **Valve** - the `steamdeck` and `steamdeck_hwmon` drivers (GPL-2.0+, Copyright Valve Corporation) in that package, and the other Steam Machine drivers
  this repository packages, published in [evlaV/linux-integration](https://github.com/evlaV/linux-integration).

## Add a package

A package built here: a folder `packages/<name>/` with its PKGBUILD (architecture-independent only; it goes into every variant). Otherwise add `<GitHub repo> <package name>` to `sources.txt`. That repository's releases must carry
`<package>-<version>-<variant>.pkg.tar.zst` and a `.sha256` for each variant, as steamify-gamescope-nvidia's do.

## Keeping it running

The hourly schedule is switched off by GitHub after 60 days without repository activity; the last step of every run enables the
workflow again to prevent that (not tried over 60 days yet: if the sync stops, start it once under Actions -> sync -> Run workflow).

A DKMS package's `pkgver` is the DKMS version: when its source changes, bump `pkgver` (not only `pkgrel`), so DKMS rebuilds cleanly.

## Older versions

Every release of a source repository is copied here, not only the newest, and the last 20 versions of each package (per CPU variant) are kept (`KEEP` in
`scripts/sync.sh`; a release that is deleted at its source stays here). A pacman database lists one version per package, the newest, so an older
one is installed from its file, which is signed like the rest (the key is already trusted when the repository is listed):

    sudo pacman -U https://github.com/theupriser/steamify-pacman-repo/releases/download/repo/steamify-gamescope-nvidia-3.16.31-3-v3.pkg.tar.zst

Why not keep everything for ever: GitHub allows 1000 files in one release (each version is a package and its signature, per variant: gamescope is 8), and a sync
that runs into it would stop for every package. 20 versions is far from that and far longer than any upgrade path or downgrade needs.

## Changing the signing key

A PC that does not trust the key refuses the repository's database, and then `pacman -Syu` (and every `pacman -S`) fails for the whole system. So never
sign with a key the PCs don't have yet:
1. Make the new key; add it to `packages/steamify-keyring/steamify.gpg` and `steamify-trusted` (keep the old one); bump `pkgver`; publish (signed with the OLD key).
2. Wait until PCs have updated the keyring (weeks, not days; `pacman -Syu` brings it).
3. Switch `GPG_PRIVATE_KEY` and `KEY_FINGERPRINT` to the new key; the next sync signs everything with it.
4. Later: put the old fingerprint in `steamify-revoked`, drop it from `steamify.gpg` and `steamify-trusted`.
A leaked private key is the one case this cannot cover (revocation cert, then a Steamify release as a separate channel). Recovery for a PC: `steamify.sh --remove-repo`.

## Setup of this repository

Secret `GPG_PRIVATE_KEY`: the armored private key of `KEY_FINGERPRINT` (no passphrase). The workflow refuses to run with another key.
