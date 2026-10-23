class Rclone < Formula
  desc "Sync daemon and CLI for PigmentDev rClone, powered by rclone"
  homepage "https://pigment.dev/products/rclone/"
  version "1.0.0-beta.1"
  license "MIT"

  # The sha256 values below are placeholders. Replace each one with the
  # checksum of the matching release archive (shasum -a 256 <file>), or copy
  # them from the checksums file attached to the GitHub release.
  on_macos do
    on_arm do
      url "https://github.com/pigment-dev/rclone/releases/download/v#{version}/pdrclone_#{version}_darwin_arm64.tar.gz"
      sha256 "0000000000000000000000000000000000000000000000000000000000000000"
    end
    on_intel do
      url "https://github.com/pigment-dev/rclone/releases/download/v#{version}/pdrclone_#{version}_darwin_amd64.tar.gz"
      sha256 "0000000000000000000000000000000000000000000000000000000000000000"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/pigment-dev/rclone/releases/download/v#{version}/pdrclone_#{version}_linux_arm64.tar.gz"
      sha256 "0000000000000000000000000000000000000000000000000000000000000000"
    end
    on_intel do
      url "https://github.com/pigment-dev/rclone/releases/download/v#{version}/pdrclone_#{version}_linux_amd64.tar.gz"
      sha256 "0000000000000000000000000000000000000000000000000000000000000000"
    end
  end

  livecheck do
    url :stable
    strategy :github_releases
  end

  def install
    bin.install "pdrclone", "pdrcloned"
  end

  service do
    run [opt_bin/"pdrcloned"]
    keep_alive true
    log_path var/"log/pdrcloned.log"
    error_log_path var/"log/pdrcloned.log"
  end

  def caveats
    <<~EOS
      To run the daemon in the background:
        brew services start pigment-dev/cli/rclone

      Or let the CLI install a LaunchAgent (macOS) or systemd user unit (Linux):
        pdrclone daemon install

      Use only one of these, not both.

      Help: https://pigment.dev/docs/rclone/
    EOS
  end

  test do
    system bin/"pdrclone", "--version"
    assert_match version.to_s, shell_output("#{bin}/pdrclone --version")
  end
end
