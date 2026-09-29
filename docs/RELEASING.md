# Releasing

OpenDeck installs marketplace plugins from the **latest GitHub release** of the repository listed in the
[OpenAction catalogue](https://github.com/OpenActionAPI/plugins): it downloads the release's `.zip` asset, takes the
plugin id from the `.sdPlugin` folder inside it and extracts it into its plugins folder. It offers an update when the
release tag (without `v`) differs from the installed plugin's manifest `Version`.

## 1. Version

Set `Version` in `Resources/manifest.json` (`MAJOR.MINOR.PATCH`). The release tag must be `v` + that version.

## 2. Package

```bash
scripts/package.sh
```

Builds a universal bundle, validates it and writes `dist/`:

| File | Use |
|---|---|
| `macos-controls.plugin.zip` | the release asset — attach exactly one `.zip` so OpenDeck does not ask which to install |
| `com.t01ik.macoscontrols.png` | 512 px icon for the catalogue PR |
| `catalogue-entry.json` | the entry to add to `catalogue.json` |
| `SHA256SUMS` | checksums |

Validation fails the script if the bundle or archive would not install cleanly: non-universal binary, missing embedded
Info.plist, invalid signature, a file referenced by the manifest missing, extra top-level entries in the zip
(e.g. `__MACOSX`), or `MacControls` losing its executable bit (OpenDeck only restores it when the zip records it).

## 3. Publish the release

```bash
git tag v1.0.0
git push origin main v1.0.0
gh release create v1.0.0 dist/macos-controls.plugin.zip --title "v1.0.0" --notes "…"
```

Users can also install the zip manually: OpenDeck → Plugins → *Install from file*.

## 4. List it in the marketplace (first release only)

1. Make the GitHub repository public and add the topic **`openaction`**.
2. Fork [OpenActionAPI/plugins](https://github.com/OpenActionAPI/plugins):
   - add `dist/catalogue-entry.json` to `catalogue.json` in the *Native OpenAction plugins* section (entries are
     sorted by repository URL); `name` and `author` must match the manifest exactly, `description` should match the
     repository description;
   - add `dist/com.t01ik.macoscontrols.png` as `icons/com.t01ik.macoscontrols.png`.
3. Open a pull request (or ask the maintainers via a GitHub issue / Matrix / Discord).

Later releases only need steps 1–3; OpenDeck picks up the new tag.

## Signing

The binary and the helper dylib are ad-hoc signed. That is enough for plugins installed through OpenDeck: it
downloads and extracts the files itself, so they carry no quarantine attribute and Gatekeeper does not assess them.
Developer ID signing and notarization are not required.

The plugin id (`com.t01ik.macoscontrols`) is the catalogue key and the folder name of every installed copy — it must
not change after the first public release.
