cask "rclone" do
  version "1.0.0-beta.7"
  sha256 "7b7300bd364442b3f13156ee6c37e21bd122af9f282ae4e288b87d36f62d7fdc"

  url "https://github.com/pigment-dev/rclone/releases/download/v#{version}/PigmentDev-rClone.dmg"
  name "PigmentDev rClone"
  desc "Sync Mac folders with Google Drive, OneDrive, Dropbox, S3 and more, powered by rclone"
  homepage "https://pigment.dev/products/rclone/"

  livecheck do
    url :url
    strategy :github_releases
  end

  depends_on macos: :sonoma
  depends_on arch: :arm64

  app "PigmentDev rClone.app"
  binary "#{appdir}/PigmentDev rClone.app/Contents/MacOS/pdrclone"

  uninstall quit:      "com.pigmentdev.rclone",
            launchctl: "com.pigmentdev.rclone.daemon"

  zap trash: [
    "~/Library/Application Support/PigmentDev rClone",
    "~/Library/Caches/com.pigmentdev.rclone*",
    "~/Library/HTTPStorages/com.pigmentdev.rclone*",
    "~/Library/LaunchAgents/com.pigmentdev.rclone*.plist",
    "~/Library/Logs/PigmentDev rClone",
    "~/Library/Preferences/com.pigmentdev.rclone*.plist",
    "~/Library/Saved Application State/com.pigmentdev.rclone.savedState",
  ]

  caveats <<~EOS
    PigmentDev rClone is not signed with an Apple Developer ID yet.
    If macOS says the app "is damaged" or "can't be opened", run:

      xattr -dr com.apple.quarantine "#{appdir}/PigmentDev rClone.app"

    Or open System Settings > Privacy & Security and click "Open Anyway".

    The sync credentials passphrase is stored in your login Keychain.
    `brew uninstall --zap` does not remove that Keychain item; delete it
    in Keychain Access if you no longer need it.

    Help: https://pigment.dev/docs/rclone/
  EOS
end
