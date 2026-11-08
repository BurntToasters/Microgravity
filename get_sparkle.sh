#!/usr/bin/env bash
# Downloads the official Sparkle release pinned in sparkle_pin.yml, verifies it, and installs it into vendor/Sparkle.
#
#   ./get_sparkle.sh                 verify, then install what differs
#   ./get_sparkle.sh --verify-only   verify the release and compare it with vendor/Sparkle; writes nothing
#   ./get_sparkle.sh --tools [DIR]   verify the release, then install the whole release (generate_keys, sign_update,
#                                    generate_appcast, ...) into DIR, default ~/Sparkle; vendor/Sparkle is not touched.
#                                    An existing DIR is moved aside to DIR.previous-<version>-<timestamp>, never deleted.
#
# Authenticity: the release tarball must match the pinned SHA-256 and GitHub's published asset digest, the tag
# must resolve to the pinned commit, and the release must report the pinned version and build. Upstream does not
# sign tags or publish attestations, so the pin is the trust anchor.
#
# Microgravity owns Package.swift (only its version defines are updated) and translations upstream does not ship
# (en.lproj). Library sources and upstream translations are updated only where the vendored copy is still
# pristine. Local edits that upstream also changed stop the script. Helpers stay ad hoc signed as upstream ships
# them; the release build signs them with the app.
set -euo pipefail

REPO="sparkle-project/Sparkle"
DEST="vendor/Sparkle"
LIB_DIRS="Sparkle Autoupdate Downloader InstallerConnection InstallerLauncher InstallerStatus"
VERIFY_ONLY=0
TOOLS_DIR=""

die() { echo "error: $*" >&2; exit 1; }
warn() { echo "warning: $*" >&2; }
step() { echo "→ $*"; }
usage() { die "usage: $0 [--verify-only | --tools [DIR]]"; }

case "${1:-}" in
    "") [ $# -le 1 ] || usage ;;
    --verify-only) [ $# -eq 1 ] || usage; VERIFY_ONLY=1 ;;
    --tools)
        [ $# -le 2 ] || usage
        TOOLS_DIR="${2:-$HOME/Sparkle}"
        [ -n "$TOOLS_DIR" ] || usage
        # Resolve against the caller's directory before changing into the repository.
        mkdir -p "$(dirname "$TOOLS_DIR")"
        TOOLS_DIR="$(cd "$(dirname "$TOOLS_DIR")" && pwd -P)/$(basename "$TOOLS_DIR")"
        case "$TOOLS_DIR" in /|"$HOME"|"$HOME/") die "refusing to use $TOOLS_DIR as the tools directory" ;; esac
        ;;
    *) usage ;;
esac
cd "$(dirname "$0")"

[ -f sparkle_pin.yml ] || die "sparkle_pin.yml not found"
pin() { awk -v key="$1" -F': *' '$1 == key { gsub(/["'\''[:space:]]/, "", $2); print $2; exit }' sparkle_pin.yml; }
VERSION="$(pin version)"; BUILD="$(pin build)"; COMMIT="$(pin commit)"; SHA256="$(pin tarball_sha256)"
VERSION_RE='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$'
[[ "$VERSION" =~ $VERSION_RE ]] || die "sparkle_pin.yml: version '$VERSION' is not a release version"
[[ "$BUILD" =~ ^[0-9]+$ ]] || die "sparkle_pin.yml: build '$BUILD' is not a number"
[[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || die "sparkle_pin.yml: commit must be a full 40-character SHA"
[[ "$SHA256" =~ ^[0-9a-f]{64}$ ]] || die "sparkle_pin.yml: tarball_sha256 must be 64 lowercase hex characters"
for tool in curl shasum git tar python3 plutil lipo codesign; do command -v "$tool" >/dev/null || die "$tool is required"; done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TARBALL="Sparkle-$VERSION.tar.xz"

fetch() { curl --proto '=https' --tlsv1.2 -fsSL --retry 2 "$@"; }
plist() { plutil -extract "$1" raw "$2" 2>/dev/null || true; }
universal() { local archs; archs="$(lipo -archs "$1")"; [[ " $archs " == *" arm64 "* && " $archs " == *" x86_64 "* ]]; }

download_release() {
    step "downloading $TARBALL from github.com/$REPO"
    fetch -o "$TMP/$TARBALL" "https://github.com/$REPO/releases/download/$VERSION/$TARBALL" || die "could not download $TARBALL"
    local actual; actual="$(shasum -a 256 "$TMP/$TARBALL" | awk '{print $1}')"
    [ "$actual" = "$SHA256" ] || die "$TARBALL SHA-256 is $actual, sparkle_pin.yml expects $SHA256"
    step "SHA-256 matches sparkle_pin.yml"
}

check_github_digest() {
    if ! fetch -H 'Accept: application/vnd.github+json' -o "$TMP/release.json" "https://api.github.com/repos/$REPO/releases/tags/$VERSION"; then
        warn "could not reach the GitHub API; relying on the pinned SHA-256 alone"
        return
    fi
    local published
    published="$(python3 -I - "$TMP/release.json" "$TARBALL" <<'PY'
import json, sys
release = json.load(open(sys.argv[1]))
asset = next((a for a in release.get("assets", []) if a.get("name") == sys.argv[2]), {})
print((asset.get("digest") or "").removeprefix("sha256:"))
PY
)"
    if [ -z "$published" ]; then warn "GitHub publishes no digest for $TARBALL; relying on the pinned SHA-256 alone"; return; fi
    [ "$published" = "$SHA256" ] || die "GitHub publishes $published for $TARBALL, sparkle_pin.yml expects $SHA256"
    step "SHA-256 matches GitHub's published digest"
}

extract_release() {
    mkdir "$TMP/release"
    tar -xJf "$TMP/$TARBALL" -C "$TMP/release"
    FW="$TMP/release/Sparkle.framework/Versions/B"
    local info
    for info in "$FW/Resources/Info.plist" "$FW/Updater.app/Contents/Info.plist"; do
        [ "$(plist CFBundleShortVersionString "$info")" = "$VERSION" ] || die "release ${info#"$TMP/release/"} is not version $VERSION"
        [ "$(plist CFBundleVersion "$info")" = "$BUILD" ] || die "release ${info#"$TMP/release/"} is not build $BUILD"
    done
    local binary
    for binary in "$FW/Autoupdate" "$FW/Updater.app/Contents/MacOS/Updater" "$TMP/release/bin/sign_update"; do
        universal "$binary" || die "${binary#"$TMP/release/"} is not universal (arm64 x86_64)"
    done
    step "release reports version $VERSION build $BUILD, universal binaries"
}

clone_tag() {
    git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$1" "https://github.com/$REPO.git" "$2" || die "could not clone tag $1"
}

clone_pinned_source() {
    step "cloning tag $VERSION"
    clone_tag "$VERSION" "$TMP/new"
    local head; head="$(git -C "$TMP/new" rev-parse HEAD)"
    [ "$head" = "$COMMIT" ] || die "tag $VERSION is commit $head, sparkle_pin.yml expects $COMMIT"
    local xcbuild; xcbuild="$(awk '$1 == "CURRENT_PROJECT_VERSION" { print $3; exit }' "$TMP/new/Configurations/ConfigCommon.xcconfig")"
    [ "$xcbuild" = "$BUILD" ] || die "tag $VERSION builds $xcbuild, sparkle_pin.yml expects $BUILD"
    step "tag $VERSION is the pinned commit"
}

# Helper bundles as they should be vendored: the upstream release bytes, ad hoc signed.
stage_helpers() {
    mkdir -p "$TMP/stage/Helpers"
    cp -R "$FW/Updater.app" "$TMP/stage/Helpers/"
    cp "$FW/Autoupdate" "$TMP/stage/Helpers/"
}

# Compares two helper trees ignoring code signatures, so a local re-sign does not count as a difference.
same_unsigned() {
    local work="$TMP/cmp" side
    rm -rf "$work"; mkdir -p "$work/a" "$work/b"
    cp -R "$1" "$work/a/"; cp -R "$2" "$work/b/"
    for side in a b; do
        find "$work/$side" -type d -name _CodeSignature -prune -exec rm -rf {} +
        while IFS= read -r file; do
            codesign --remove-signature "$file" 2>/dev/null || true
        done < <(find "$work/$side" -type f -perm -u+x)
    done
    diff -rq "$work/a" "$work/b" >/dev/null
}

# Paths under Sources/Sparkle that come from upstream, with their upstream location. Prints "vendored<TAB>upstream".
# Headers were flattened in LIB_DIRS order, so a name in several directories (SUInstallerProtocol.h) maps to the last.
vendored_sources() {
    local rel base dir found
    while IFS= read -r rel; do
        base="$(basename "$rel")"; found=""
        case "$rel" in
            ed25519/*) found="Vendor/ed25519-sparkle/src/$base" ;;
            ReleaseNotesColorStyle.css) found="Resources/$base" ;;
            *.lproj/*) found="Sparkle/$rel" ;;
            *.xib) found="Sparkle/$base" ;;
            *) for dir in $LIB_DIRS; do
                   if [ -f "$TMP/new/$dir/$base" ] || [ -f "$OLD_SRC/$dir/$base" ]; then found="$dir/$base"; fi
               done ;;
        esac
        printf '%s\t%s\n' "$rel" "$found"
    done < <(cd "$DEST/Sources/Sparkle" && find . -type f \( -name '*.[mhc]' -o -name '*.xib' -o -name '*.css' -o -path '*.lproj/*' \) | sed 's|^\./||' | sort)
}

library_files() {
    { (cd "$1" && for dir in $LIB_DIRS Vendor/ed25519-sparkle/src; do ls "$dir" 2>/dev/null | sed "s|^|$dir/|"; done) | grep -E '\.[mhc]$'
      (cd "$1" && find Sparkle -path '*.lproj/*' -type f); } | sort
}

plan_sources() {
    : > "$TMP/updates"; : > "$TMP/kept"; : > "$TMP/conflicts"
    if [ "$OLD_VERSION" != "$VERSION" ]; then
        local added; added="$(diff <(library_files "$OLD_SRC") <(library_files "$TMP/new") || true)"
        [ -z "$added" ] || die "upstream added or removed library or translation files between $OLD_VERSION and $VERSION; review vendor/Sparkle by hand:
$added"
    fi
    local rel up vendored
    while IFS="$(printf '\t')" read -r rel up; do
        vendored="$DEST/Sources/Sparkle/$rel"
        # Translations upstream never shipped (en.lproj) are Microgravity's own.
        if [[ "$rel" == *.lproj/* && ! -f "$TMP/new/$up" && ! -f "$OLD_SRC/$up" ]]; then continue; fi
        if [ -z "$up" ] || [ ! -f "$TMP/new/$up" ]; then echo "$rel (not in Sparkle $VERSION)" >> "$TMP/conflicts"; continue; fi
        cmp -s "$vendored" "$TMP/new/$up" && continue
        if [ -f "$OLD_SRC/$up" ] && cmp -s "$vendored" "$OLD_SRC/$up"; then printf '%s\t%s\n' "$rel" "$up" >> "$TMP/updates"; continue; fi
        if [ -f "$OLD_SRC/$up" ] && cmp -s "$OLD_SRC/$up" "$TMP/new/$up"; then echo "$rel" >> "$TMP/kept"; continue; fi
        echo "$rel (local edit, and upstream changed it)" >> "$TMP/conflicts"
    done < <(vendored_sources)
    if [ -s "$TMP/kept" ]; then step "keeping local edits upstream did not touch:"; sed 's/^/    /' "$TMP/kept"; fi
}

read_old_version() {
    [ -f "$DEST/UPSTREAM" ] || die "$DEST/UPSTREAM is missing; cannot tell which vendored files are pristine"
    OLD_VERSION="$(sed -n 's/^VERSION=//p' "$DEST/UPSTREAM")"
    [ -n "$OLD_VERSION" ] || die "$DEST/UPSTREAM has no VERSION"
    if [ "$OLD_VERSION" = "$VERSION" ]; then OLD_SRC="$TMP/new"; return; fi
    step "cloning vendored tag $OLD_VERSION to find pristine files"
    clone_tag "$OLD_VERSION" "$TMP/old"
    OLD_SRC="$TMP/old"
}

package_versions() { python3 -I - "$DEST/Package.swift" "$@" <<'PY'
import re, sys
path, *update = sys.argv[1:]
text = open(path).read()
pattern = r'(\.define\("{}", to: "\\")([^"\\]*)(\\""\))'
if update:
    for key, value in (("MARKETING_VERSION", update[0]), ("CURRENT_PROJECT_VERSION", update[1])):
        text, count = re.subn(pattern.format(key), lambda m: m.group(1) + value + m.group(3), text)
        if count != 1: sys.exit(f"Package.swift: expected one {key} define, found {count}")
    open(path, "w").write(text)
else:
    found = [re.search(pattern.format(key), text) for key in ("MARKETING_VERSION", "CURRENT_PROJECT_VERSION")]
    print(" ".join(m.group(2) if m else "missing" for m in found))
PY
}

verify_vendored() {
    local problems=0 count
    if same_unsigned "$TMP/stage/Helpers" "$DEST/Helpers"; then step "vendored helpers match the official release (ignoring signatures)"
    else echo "✗ vendored helpers differ from the official $VERSION release"; problems=1; fi
    if cmp -s "$TMP/release/bin/sign_update" "$DEST/bin/sign_update"; then step "vendored sign_update matches the official release"
    else echo "✗ vendored sign_update differs from the official $VERSION release"; problems=1; fi
    [ "$OLD_VERSION" = "$VERSION" ] || { echo "✗ $DEST/UPSTREAM is $OLD_VERSION, pin is $VERSION"; problems=1; }
    [ "$(package_versions)" = "$VERSION $BUILD" ] || { echo "✗ $DEST/Package.swift defines $(package_versions), pin is $VERSION $BUILD"; problems=1; }
    count="$(wc -l < "$TMP/updates" | tr -d ' ')"
    [ "$count" = 0 ] || { echo "✗ $count vendored source files are not Sparkle $VERSION:"; cut -f1 "$TMP/updates" | sed 's/^/    /'; problems=1; }
    [ ! -s "$TMP/conflicts" ] || { echo "✗ vendored sources conflict with Sparkle $VERSION:"; sed 's/^/    /' "$TMP/conflicts"; problems=1; }
    [ "$problems" = 0 ] || die "vendor/Sparkle does not match sparkle_pin.yml; run ./get_sparkle.sh"
    echo "✓ vendor/Sparkle matches the official Sparkle $VERSION release"
}

update_docs() {
    [ "$OLD_VERSION" != "$VERSION" ] || return 0
    python3 -I - "$OLD_VERSION" "$VERSION" <<'PY'
import sys
from pathlib import Path
old, new = sys.argv[1:]
edits = {
    "THIRD_PARTY_NOTICES.md": [
        (f"## Sparkle {old}\n", f"## Sparkle {new}\n"),
        (f"/Sparkle/tree/{old}>", f"/Sparkle/tree/{new}>"),
        (f"/releases/download/{old}/Sparkle-{old}.tar.xz>", f"/releases/download/{new}/Sparkle-{new}.tar.xz>"),
    ],
}
for name, pairs in edits.items():
    path = Path(name); text = path.read_text()
    for before, after in pairs:
        if before not in text: print(f"warning: {name} has no '{before.strip()}' to update", file=sys.stderr)
        text = text.replace(before, after)
    path.write_text(text)
PY
}

install() {
    [ ! -s "$TMP/conflicts" ] || { echo "Vendored sources conflict with Sparkle $VERSION:"; sed 's/^/    /' "$TMP/conflicts"; die "resolve these by hand; nothing was changed"; }
    local helpers_changed=0
    same_unsigned "$TMP/stage/Helpers" "$DEST/Helpers" || helpers_changed=1
    local rel up
    while IFS="$(printf '\t')" read -r rel up; do cp "$TMP/new/$up" "$DEST/Sources/Sparkle/$rel"; echo "    updated $rel"; done < "$TMP/updates"
    if [ "$helpers_changed" = 1 ]; then
        rm -rf "$DEST/Helpers"; mv "$TMP/stage/Helpers" "$DEST/Helpers"; step "installed helpers"
    else
        step "helpers already match the official release"
    fi
    cmp -s "$TMP/release/bin/sign_update" "$DEST/bin/sign_update" || { cp "$TMP/release/bin/sign_update" "$DEST/bin/sign_update"; step "installed sign_update"; }
    chmod +x "$DEST/bin/sign_update" "$DEST/Helpers/Autoupdate"
    [ "$(package_versions)" = "$VERSION $BUILD" ] || package_versions "$VERSION" "$BUILD"
    if [ "$OLD_VERSION" != "$VERSION" ] || ! grep -qx "COMMIT=$COMMIT" "$DEST/UPSTREAM"; then
        printf 'VERSION=%s\nCOMMIT=%s\nSHA256=%s\nSOURCE=%s\nDATE=%s\n' "$VERSION" "$COMMIT" "$SHA256" \
            "https://github.com/$REPO/releases/download/$VERSION/$TARBALL" "$(date -u +%Y-%m-%d)" > "$DEST/UPSTREAM"
    fi
    update_docs
    echo "✓ vendor/Sparkle is the official Sparkle $VERSION release"
    git status --short -- "$DEST" THIRD_PARTY_NOTICES.md
    echo "Next: npm run validate && npm run test:all, add a CHANGELOG.md entry, and commit."
}

# Installs the verified release as a whole into TOOLS_DIR. Keys live in the login keychain, not in this directory.
install_tools() {
    local tool
    for tool in generate_keys generate_appcast sign_update BinaryDelta; do
        [ -x "$TMP/release/bin/$tool" ] || die "release has no bin/$tool"
        universal "$TMP/release/bin/$tool" || die "bin/$tool is not universal (arm64 x86_64)"
    done
    local info="Sparkle.framework/Versions/B/Resources/Info.plist" old_version="" old_build=""
    if [ -e "$TOOLS_DIR" ]; then
        [ -d "$TOOLS_DIR" ] || die "$TOOLS_DIR exists and is not a directory"
        if [ -n "$(ls -A "$TOOLS_DIR")" ] && [ ! -d "$TOOLS_DIR/Sparkle.framework" ] && [ ! -x "$TOOLS_DIR/bin/sign_update" ]; then
            die "$TOOLS_DIR does not look like a Sparkle release; choose another directory"
        fi
        old_version="$(plist CFBundleShortVersionString "$TOOLS_DIR/$info")"; old_build="$(plist CFBundleVersion "$TOOLS_DIR/$info")"
        if [ "$old_version" = "$VERSION" ] && [ "$old_build" = "$BUILD" ] && diff -rq -x .DS_Store "$TMP/release" "$TOOLS_DIR" >/dev/null 2>&1; then
            echo "✓ $TOOLS_DIR already is the official Sparkle $VERSION release"; return
        fi
        if [ -n "$old_build" ] && [ "$old_build" -gt "$BUILD" ] 2>/dev/null; then
            warn "$TOOLS_DIR has Sparkle $old_version (build $old_build), newer than the pinned $VERSION (build $BUILD); installing the pinned release anyway"
        fi
        local backup; backup="$TOOLS_DIR.previous-${old_version:-unknown}-$(date +%Y%m%d%H%M%S)"
        mv "$TOOLS_DIR" "$backup"
        step "moved the existing $TOOLS_DIR to $backup"
    fi
    mv "$TMP/release" "$TOOLS_DIR"
    echo "✓ $TOOLS_DIR is the official Sparkle $VERSION release"
    echo "Keys: $TOOLS_DIR/bin/generate_keys --account microgravity   (prints the public key, creating the key if missing)"
}

download_release
check_github_digest
extract_release
clone_pinned_source
if [ -n "$TOOLS_DIR" ]; then install_tools; exit 0; fi
read_old_version
stage_helpers
plan_sources
if [ "$VERIFY_ONLY" = 1 ]; then verify_vendored; else install; fi
