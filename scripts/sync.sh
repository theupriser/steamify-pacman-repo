#!/usr/bin/env bash
# Copies the newest release of every repo in sources.txt into the pacman repository: one database per CPU variant
# (steamify-generic, steamify-v3, steamify-v4, steamify-znver4), all files as assets of the release tagged $TAG of this
# repository. Packages and databases are signed with the key in GPG_PRIVATE_KEY.
# Needs: gh, gnupg, pacman (repo-add), curl; GH_TOKEN, GPG_PRIVATE_KEY, GITHUB_REPOSITORY; run from the repository root.
set -euo pipefail

TAG="${TAG:-repo}"
KEEP="${KEEP:-20}"   # versions kept per package and variant, for downgrades (the files are small; the databases list only the newest)
VARIANTS=(generic v3 v4 znver4)
here="$(pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

export GNUPGHOME="$work/gnupg"; mkdir -m700 "$GNUPGHOME"
printf '%s\n' "$GPG_PRIVATE_KEY" | gpg --batch --import 2>/dev/null
key="$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr/{print $10; exit}')"
[[ -n "$key" ]] || { echo "no signing key imported" >&2; exit 1; }
[[ "$key" == "$(< KEY_FINGERPRINT)" ]] || { echo "the imported key $key is not the one in KEY_FINGERPRINT" >&2; exit 1; }

gh release view "$TAG" >/dev/null 2>&1 || gh release create "$TAG" --title "pacman repository" \
    --notes "The files of the Steamify pacman repository. Not a release: see the README. Rewritten by the sync workflow."

gh release view "$TAG" --json assets --jq '.assets[].name' | sort > "$work/ours"

sign() { gpg --batch --yes --detach-sign --no-armor --local-user "$key" -o "$1.sig" "$1"; }

# db_publish <variant> <dir>: uploads the variant's database and file list from <dir> (repo-add and repo-remove leave them as
# steamify-<v>.db.tar.zst; the release has plain files steamify-<v>.db).
db_publish() {
    local v="$1" d="$2" ext
    local -a up=()
    for ext in db files; do
        # repo-add leaves symlinks (steamify-v3.db -> .db.tar.zst); release assets are plain files
        rm -f "$d/steamify-$v.$ext" "$d/steamify-$v.$ext.sig"
        cp "$d/steamify-$v.$ext.tar.zst" "$d/steamify-$v.$ext"
        cp "$d/steamify-$v.$ext.tar.zst.sig" "$d/steamify-$v.$ext.sig"
        up+=("$d/steamify-$v.$ext" "$d/steamify-$v.$ext.sig")
    done
    gh release upload "$TAG" "${up[@]}" --clobber
}

# db_fetch <variant> <dir>: the variant's database and file list from the release, as steamify-<v>.db.tar.zst (not there: nothing).
db_fetch() {
    local v="$1" d="$2" ext
    for ext in db files; do gh release download "$TAG" -p "steamify-$v.$ext" -D "$d" --clobber 2>/dev/null \
        && mv "$d/steamify-$v.$ext" "$d/steamify-$v.$ext.tar.zst" || true; done
}

# db_add <variant> <package file> <dir with the package and its .sig>: the package goes into that variant's database (an
# older entry of the same package is replaced; repo-add reads the package inside, not its file name), and the database is uploaded.
db_add() {
    local v="$1" file="$2" d="$3"
    db_fetch "$v" "$d"
    (cd "$d" && repo-add --sign --key "$key" "steamify-$v.db.tar.zst" "$file")
    db_publish "$v" "$d"
}

# prune <package name> <variant|any>: keep the newest $KEEP package files
prune() {
    local pkg="$1" v="$2" f
    local -a old
    mapfile -t old < <(gh release view "$TAG" --json assets --jq '.assets[].name' \
        | grep -E "^$pkg-.*-$v\.pkg\.tar\.zst$" | sort -V | head -n -"$KEEP")
    for f in "${old[@]}"; do [[ -n "$f" ]] && gh release delete-asset "$TAG" "$f" "$f.sig" -y 2>/dev/null || true; done
    gh release view "$TAG" --json assets --jq '.assets[].name' | sort > "$work/ours"
}

changed=0

# fetch_release <source repo> <package name> <release tag> <newest|older>: the four CPU variants of one release of a source repo:
# checked against their .sha256, signed, uploaded. Only the NEWEST release goes into the databases (a database lists one version per
# package); an older one is an archive of files for `pacman -U <asset url>` (a downgrade, or a PC that needs the version it was set up
# with), so repo-add never has to choose between versions.
fetch_release() {
    local src="$1" pkg="$2" tag="$3" kind="$4" v file d missing=0
    # Everything already here: no call to the source repo (this runs every hour).
    for v in "${VARIANTS[@]}"; do grep -qxF "$pkg-$tag-$v.pkg.tar.zst" "$work/ours" || missing=1; done
    (( missing )) || { echo "$pkg $tag: already in the repository"; return 0; }
    gh release view --repo "$src" "$tag" --json assets --jq '.assets[].name' > "$work/theirs"
    for v in "${VARIANTS[@]}"; do
        file="$pkg-$tag-$v.pkg.tar.zst"
        grep -qxF "$file" "$work/theirs" || { echo "$src $tag: no $v build, skipped"; continue; }
        if grep -qxF "$file" "$work/ours"; then echo "$file: already in the repository"; continue; fi

        d="$work/$v"; mkdir -p "$d"
        gh release download --repo "$src" "$tag" -p "$file" -p "$file.sha256" -D "$d" --clobber
        (cd "$d" && sha256sum -c "$file.sha256")
        sign "$d/$file"
        gh release upload "$TAG" "$d/$file" "$d/$file.sig" --clobber
        [[ "$kind" == newest ]] && db_add "$v" "$file" "$d"
        changed=1
        prune "$pkg" "$v"
    done
}

while read -r src pkg; do
    [[ -z "$src" || "$src" == \#* ]] && continue
    srctag="$(gh release view --repo "$src" --json tagName --jq .tagName 2>/dev/null)" || { echo "$src: no release, skipped"; continue; }
    # The older releases first (oldest to newest, drafts and prereleases left out), then the newest into the databases: a release
    # that is deleted at its source stays here, since this repository is the archive.
    mapfile -t older < <(gh release list --repo "$src" --limit 100 --json tagName,isDraft,isPrerelease,publishedAt \
        --jq 'map(select((.isDraft|not) and (.isPrerelease|not)))|sort_by(.publishedAt)|.[].tagName' 2>/dev/null)
    for tag in "${older[@]}"; do
        [[ "$tag" == "$srctag" ]] && continue
        fetch_release "$src" "$pkg" "$tag" older
    done
    fetch_release "$src" "$pkg" "$srctag" newest
done < "$here/sources.txt"

# Packages built in this repository (packages/<name>/PKGBUILD, built by the workflow into $LOCAL_PKGS): architecture-independent
# ones go into the database of every variant.
if [[ -n "${LOCAL_PKGS:-}" && -d "$LOCAL_PKGS" ]]; then
    for p in "$LOCAL_PKGS"/*-any.pkg.tar.zst; do
        [[ -e "$p" ]] || continue
        file="${p##*/}"
        if grep -qxF "$file" "$work/ours"; then echo "$file: already in the repository"; continue; fi
        pkgname="$(bsdtar -xOf "$p" .PKGINFO | awk -F' = ' '$1 == "pkgname" {print $2}')"
        d="$work/any"; mkdir -p "$d"; cp "$p" "$d/$file"; sign "$d/$file"
        gh release upload "$TAG" "$d/$file" "$d/$file.sig" --clobber
        for v in "${VARIANTS[@]}"; do db_add "$v" "$file" "$d"; done
        changed=1
        prune "$pkgname" any
    done
fi

# retire: a package that is neither in sources.txt nor in packages/ any more (renamed or dropped) leaves every database and its
# files are deleted, so a rename does not leave a dead entry behind. Nothing is retired when the list of wanted packages is
# empty (a broken sources.txt must not empty the repository), and not more than $RETIRE_MAX packages in one run.
RETIRE_MAX="${RETIRE_MAX:-3}"
retire() {
    local v d f name
    local -a keep=() gone=() all=()
    while read -r src pkg; do [[ -z "$src" || "$src" == \#* ]] || keep+=("$pkg"); done < "$here/sources.txt"
    for f in "$here"/packages/*/PKGBUILD; do
        [[ -e "$f" ]] || continue
        name="$(sed -n 's/^pkgname=//p' "$f" | head -n 1 | tr -d "\"'")"
        [[ -n "$name" ]] && keep+=("$name")
    done
    (( ${#keep[@]} )) || { echo "retire: no wanted packages found, nothing retired" >&2; return 0; }
    for v in "${VARIANTS[@]}"; do
        d="$work/retire-$v"; mkdir -p "$d"
        db_fetch "$v" "$d"
        [[ -f "$d/steamify-$v.db.tar.zst" ]] || continue
        # the entries are folders <name>-<pkgver>-<pkgrel>/
        mapfile -t all < <(bsdtar -tf "$d/steamify-$v.db.tar.zst" | sed -n 's|^\(.*\)-[^-]*-[^-]*/desc$|\1|p' | sort -u)
        gone=()
        for name in "${all[@]}"; do
            printf '%s\n' "${keep[@]}" | grep -qxF -- "$name" || gone+=("$name")
        done
        (( ${#gone[@]} )) || continue
        (( ${#gone[@]} <= RETIRE_MAX )) || { echo "retire: $v would lose ${#gone[@]} packages (${gone[*]}), more than $RETIRE_MAX: not touching it" >&2; continue; }
        echo "retire: $v database drops ${gone[*]}"
        (cd "$d" && repo-remove --sign --key "$key" "steamify-$v.db.tar.zst" "${gone[@]}")
        db_publish "$v" "$d"
        changed=1
    done
    # their files, once no database lists them
    for name in $(gh release view "$TAG" --json assets --jq '.assets[].name' | sed -n 's/^\(steamify-.*\)-[^-]*-[^-]*-[^-]*\.pkg\.tar\.zst$/\1/p' | sort -u); do
        printf '%s\n' "${keep[@]}" | grep -qxF -- "$name" && continue
        for f in $(gh release view "$TAG" --json assets --jq '.assets[].name' | grep -E "^$name-[^-]*-[^-]*-[^-]*\.pkg\.tar\.zst$"); do
            echo "retire: deleting $f"; gh release delete-asset "$TAG" "$f" "$f.sig" -y 2>/dev/null || true
        done
    done
}
retire

(( changed )) && echo "repository updated" || echo "nothing new"
