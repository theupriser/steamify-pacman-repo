#!/usr/bin/env bash
# Copies the newest release of every repo in sources.txt into the pacman repository: one database per CPU variant
# (steamify-generic, steamify-v3, steamify-v4, steamify-znver4), all files as assets of the release tagged $TAG of this
# repository. Packages and databases are signed with the key in GPG_PRIVATE_KEY.
# Needs: gh, gnupg, pacman (repo-add), curl; GH_TOKEN, GPG_PRIVATE_KEY, GITHUB_REPOSITORY; run from the repository root.
set -euo pipefail

TAG="${TAG:-repo}"
KEEP="${KEEP:-2}"   # versions kept per package and variant, for downgrades
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

changed=0
while read -r src pkg; do
    [[ -z "$src" || "$src" == \#* ]] && continue
    srctag="$(gh release view --repo "$src" --json tagName --jq .tagName 2>/dev/null)" || { echo "$src: no release, skipped"; continue; }
    gh release view --repo "$src" "$srctag" --json assets --jq '.assets[].name' > "$work/theirs"
    for v in "${VARIANTS[@]}"; do
        file="$pkg-$srctag-$v.pkg.tar.zst"
        grep -qxF "$file" "$work/theirs" || { echo "$src $srctag: no $v build, skipped"; continue; }
        if grep -qxF "$file" "$work/ours"; then echo "$file: already in the repository"; continue; fi

        d="$work/$v"; mkdir -p "$d"
        gh release download --repo "$src" "$srctag" -p "$file" -p "$file.sha256" -D "$d" --clobber
        (cd "$d" && sha256sum -c "$file.sha256")
        for ext in db files; do gh release download "$TAG" -p "steamify-$v.$ext" -D "$d" --clobber 2>/dev/null \
            && mv "$d/steamify-$v.$ext" "$d/steamify-$v.$ext.tar.zst" || true; done

        sign "$d/$file"
        # repo-add reads the package inside, not its file name; an old entry of the same package is replaced
        (cd "$d" && repo-add --sign --key "$key" "steamify-$v.db.tar.zst" "$file")

        up=("$d/$file" "$d/$file.sig")
        for ext in db files; do
            # repo-add leaves symlinks (steamify-v3.db -> .db.tar.zst); release assets are plain files
            rm -f "$d/steamify-$v.$ext" "$d/steamify-$v.$ext.sig"
            cp "$d/steamify-$v.$ext.tar.zst" "$d/steamify-$v.$ext"
            cp "$d/steamify-$v.$ext.tar.zst.sig" "$d/steamify-$v.$ext.sig"
            up+=("$d/steamify-$v.$ext" "$d/steamify-$v.$ext.sig")
        done
        gh release upload "$TAG" "${up[@]}" --clobber
        changed=1

        # Older package files of this variant: keep the newest $KEEP versions
        mapfile -t old < <(gh release view "$TAG" --json assets --jq '.assets[].name' \
            | grep -E "^$pkg-.*-$v\.pkg\.tar\.zst$" | sort -V | head -n -"$KEEP")
        for f in "${old[@]}"; do [[ -n "$f" ]] && gh release delete-asset "$TAG" "$f" "$f.sig" -y 2>/dev/null || true; done
        gh release view "$TAG" --json assets --jq '.assets[].name' | sort > "$work/ours"
    done
done < "$here/sources.txt"

(( changed )) && echo "repository updated" || echo "nothing new"
