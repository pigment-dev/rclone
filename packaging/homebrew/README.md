# Homebrew packaging

Source of truth for the two Homebrew packages. Homebrew reads them from the tap repository [`pigment-dev/homebrew-gui`](https://github.com/pigment-dev/homebrew-gui), not from here.

| File | Tap path | Installs |
|---|---|---|
| `rclone.rb` | `Casks/rclone.rb` | The macOS app, and links the `pdrclone` CLI from inside the bundle. Apple Silicon, macOS 14+. |
| `pdrclone.rb` | `Formula/pdrclone.rb` | The `pdrclone` CLI and `pdrcloned` daemon only, for macOS and Linux. |

```sh
brew install --cask pigment-dev/gui/rclone   # the Mac app (includes the CLI)
brew install pigment-dev/gui/pdrclone        # CLI and daemon only
```

Both provide a `pdrclone` command, so install one or the other.

## Updating after a release

```sh
V=$(cat VERSION)
gh release download "v$V" -R pigment-dev/rclone -p "PigmentDev-rClone.dmg" -p "checksums.txt" -D /tmp/pd-release
shasum -a 256 /tmp/pd-release/PigmentDev-rClone.dmg   # -> sha256 in rclone.rb
cat /tmp/pd-release/checksums.txt                     # -> the four sha256 values in pdrclone.rb
```

Set `version` and the checksums in both files, copy them into the tap (`Casks/` and `Formula/`), run `brew audit --strict pigment-dev/gui/rclone`, and push the tap.
