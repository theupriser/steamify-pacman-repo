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
| `steamify-steamdeck-dkms` | `packages/` (any): Valve's `steamdeck` and `steamdeck_hwmon` drivers, built only for kernels that lack them (SteamOS's kernels have them); contributed by Toxican | the Steam Machine's fan monitoring and OS fan control (with `jupiter-fan-control`) |

Architecture-independent packages are in every variant's database.

## Add a package

A package built here: a folder `packages/<name>/` with its PKGBUILD (architecture-independent only; it goes into every variant). Otherwise add `<GitHub repo> <package name>` to `sources.txt`. That repository's releases must carry
`<package>-<version>-<variant>.pkg.tar.zst` and a `.sha256` for each variant, as steamify-gamescope-nvidia's do.

## Keeping it running

The hourly schedule is switched off by GitHub after 60 days without repository activity; the last step of every run enables the
workflow again to prevent that (not tried over 60 days yet: if the sync stops, start it once under Actions -> sync -> Run workflow).

A DKMS package's `pkgver` is the DKMS version: when its source changes, bump `pkgver` (not only `pkgrel`), so DKMS rebuilds cleanly.

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
