#!/bin/bash
# Builds the plugin and packages it for a GitHub release / the OpenAction Marketplace.
#
#   scripts/package.sh                  → dist/
#
# dist/ then contains:
#   macos-controls.plugin.zip          the release asset (OpenDeck installs the latest release's .zip)
#   com.t01ik.macoscontrols.png        512 px icon for the marketplace catalogue PR (icons/<bundle id>.png)
#   catalogue-entry.json               entry for catalogue.json in github.com/OpenActionAPI/plugins
#   SHA256SUMS
#
# Release checklist: docs/RELEASING.md.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BUNDLE_ID="com.t01ik.macoscontrols"
BUNDLE="build/$BUNDLE_ID.sdPlugin"
DIST="dist"
ASSET="macos-controls.plugin.zip"

"$ROOT/scripts/build.sh"

manifest() { /usr/bin/python3 -c "import json,sys; print(json.load(open('Resources/manifest.json'))[sys.argv[1]])" "$1"; }
VERSION="$(manifest Version)"
NAME="$(manifest Name)"
AUTHOR="$(manifest Author)"
DESCRIPTION="$(manifest Description)"

echo "→ Validating bundle ($NAME $VERSION)"
fail() { echo "✗ $*" >&2; exit 1; }

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "manifest Version '$VERSION' must be MAJOR.MINOR.PATCH (compared with the release tag)"
ARCHS="$(lipo -archs "$BUNDLE/MacControls")"
[[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]] || fail "MacControls is not universal ($ARCHS)"
[[ "$(lipo -archs "$BUNDLE/libnowplaying.dylib")" == *arm64* ]] || fail "libnowplaying.dylib is missing arm64"
otool -arch arm64 -s __TEXT __info_plist "$BUNDLE/MacControls" | grep -q __info_plist || fail "Info.plist is not embedded in MacControls"
codesign --verify "$BUNDLE/MacControls" "$BUNDLE/libnowplaying.dylib" || fail "code signature is invalid"

# Every file the manifest points to must exist in the bundle.
/usr/bin/python3 - "$BUNDLE" <<'PY' || fail "manifest references missing files"
import json, os, sys
bundle = sys.argv[1]
manifest = json.load(open(os.path.join(bundle, "manifest.json")))
def image(path): return any(os.path.exists(os.path.join(bundle, path + ext)) for ext in (".png", "@2x.png", ".svg"))
missing = [p for p in (manifest["Icon"], manifest["CategoryIcon"]) if not image(p)]
for action in manifest["Actions"]:
    missing += [p for p in [action["Icon"]] + [s["Image"] for s in action["States"]] if not image(p)]
    encoder = action.get("Encoder") or {}
    if encoder.get("Icon") and not image(encoder["Icon"]): missing.append(encoder["Icon"])
    layout = encoder.get("layout", "$")
    if not layout.startswith("$") and not os.path.exists(os.path.join(bundle, layout)): missing.append(layout)
    inspector = action.get("PropertyInspectorPath")
    if inspector and not os.path.exists(os.path.join(bundle, inspector)): missing.append(inspector)
code = manifest.get("CodePathMac") or manifest.get("CodePath")
if not os.access(os.path.join(bundle, code), os.X_OK): missing.append(code + " (not executable)")
if missing:
    print("missing:", ", ".join(missing), file=sys.stderr)
    sys.exit(1)
print(f"  {len(manifest['Actions'])} actions, all references present")
PY

echo "→ Packaging"
rm -rf "$DIST"
mkdir -p "$DIST"
# zip (not ditto) stores Unix permissions without AppleDouble/__MACOSX entries: OpenDeck's extractor keeps the
# executable bit only if it is recorded, and would extract any extra top-level folders into the plugins directory.
(cd build && /usr/bin/zip -qr -X "../$DIST/$ASSET" "$BUNDLE_ID.sdPlugin" -x "*.DS_Store")

# The archive must contain exactly one top-level folder, the .sdPlugin, and keep MacControls executable.
TOP="$(/usr/bin/zipinfo -1 "$DIST/$ASSET" | cut -d/ -f1 | sort -u)"
[[ "$TOP" == "$BUNDLE_ID.sdPlugin" ]] || fail "unexpected top-level entries in the zip: $TOP"
/usr/bin/zipinfo "$DIST/$ASSET" "$BUNDLE_ID.sdPlugin/MacControls" | grep -q '^-rwx' || fail "MacControls lost its executable bit in the zip"

"$BUNDLE/MacControls" --plugin-icon "$DIST/$BUNDLE_ID.png" 512

REPOSITORY="$(git config --get remote.origin.url 2>/dev/null | sed -E 's#^git@github.com:#https://github.com/#; s#\.git$##' || true)"
/usr/bin/python3 - "$BUNDLE_ID" "$NAME" "$AUTHOR" "${REPOSITORY:-https://github.com/<owner>/<repository>}" "$DESCRIPTION" > "$DIST/catalogue-entry.json" <<'PY'
import json, sys
bundle_id, name, author, repository, description = sys.argv[1:]
print(json.dumps({bundle_id: {"name": name, "author": author, "repository": repository, "description": description}},
                 indent="\t", ensure_ascii=False))
PY

(cd "$DIST" && shasum -a 256 "$ASSET" "$BUNDLE_ID.png" > SHA256SUMS)

echo "✓ Packaged $NAME $VERSION"
ls -l "$DIST" | tail -n +2 | awk '{printf "    %-34s %8s bytes\n", $NF, $5}'
TAG="v$VERSION"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
	[[ "$(git rev-list -n1 "$TAG")" == "$(git rev-parse HEAD)" ]] || echo "! tag $TAG exists but does not point at HEAD"
else
	echo "  Next: git tag $TAG && git push origin $TAG, then publish a GitHub release $TAG with dist/$ASSET (see docs/RELEASING.md)"
fi
