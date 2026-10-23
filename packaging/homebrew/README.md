# Homebrew packaging

Source of truth for the two Homebrew packages. Homebrew reads them from the tap repositories [`pigment-dev/homebrew-gui`](https://github.com/pigment-dev/homebrew-gui) (apps) and [`pigment-dev/homebrew-cli`](https://github.com/pigment-dev/homebrew-cli) (command-line tools), not from here.

| File | Tap path | Installs |
|---|---|---|
| `Casks/rclone.rb` | `homebrew-gui/Casks/rclone.rb` | The macOS app, and links the `pdrclone` CLI from inside the bundle. Apple Silicon, macOS 14+. |
| `Formula/rclone.rb` | `homebrew-cli/Formula/rclone.rb` | The `pdrclone` CLI and `pdrcloned` daemon only, for macOS and Linux. |

```sh
brew install --cask pigment-dev/gui/rclone   # the Mac app (includes the CLI)
brew install pigment-dev/cli/rclone        # CLI and daemon only
```

Both provide a `pdrclone` command, so install one or the other.

## Updating after a release

```sh
V=$(cat VERSION)
gh release download "v$V" -R pigment-dev/rclone -p "PigmentDev-rClone.dmg" -p "checksums.txt" -D /tmp/pd-release
shasum -a 256 /tmp/pd-release/PigmentDev-rClone.dmg   # -> sha256 in Casks/rclone.rb
cat /tmp/pd-release/checksums.txt                     # -> the four sha256 values in Formula/rclone.rb
```

Set `version` and the checksums in both files, copy them into the taps, run `brew audit --strict pigment-dev/gui/rclone` and `brew audit --strict pigment-dev/cli/rclone`, and push both taps.
