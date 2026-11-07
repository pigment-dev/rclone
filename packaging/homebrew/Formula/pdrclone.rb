class Pdrclone < Formula
  desc "Sync daemon and CLI for PigmentDev rClone, powered by rclone"
  homepage "https://pigment.dev/products/rclone/"
  version "1.0.0-beta.9"
  license "MIT"

  on_macos do
    on_arm do
      url "https://github.com/pigment-dev/rclone/releases/download/v#{version}/pdrclone_#{version}_darwin_arm64.tar.gz"
      sha256 "d854114b3ad9f85542f21315d3fc18b7ed4b13fd67f25a19ef86b40b98bce5ba"
    end
    on_intel do
      url "https://github.com/pigment-dev/rclone/releases/download/v#{version}/pdrclone_#{version}_darwin_amd64.tar.gz"
      sha256 "51839dceaf7f6e304244b1a54c693cc360a4d11c2620edba7fc9f61af7677141"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/pigment-dev/rclone/releases/download/v#{version}/pdrclone_#{version}_linux_arm64.tar.gz"
      sha256 "7b9e7aa5f5c762f8085280dd421b65abc24b53f533efd353b022d2c019dd15b4"
    end
    on_intel do
      url "https://github.com/pigment-dev/rclone/releases/download/v#{version}/pdrclone_#{version}_linux_amd64.tar.gz"
      sha256 "787346bd030fa038a6f7ec26ee6cd75041d56ad05f73399622a3648003422422"
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
        brew services start pigment-dev/cli/pdrclone

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
