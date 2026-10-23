class Pdrclone < Formula
  desc "Sync daemon and CLI for PigmentDev rClone, powered by rclone"
  homepage "https://pigment.dev/products/rclone/"
  version "1.0.0-beta.4"
  license "MIT"

  on_macos do
    on_arm do
      url "https://github.com/pigment-dev/rclone/releases/download/v#{version}/pdrclone_#{version}_darwin_arm64.tar.gz"
      sha256 "4db2d58975ad24148819cf74b123e08a5d3a937d20c284d65a4147f0ea33ab58"
    end
    on_intel do
      url "https://github.com/pigment-dev/rclone/releases/download/v#{version}/pdrclone_#{version}_darwin_amd64.tar.gz"
      sha256 "88494bcefd88debed1e43783879eb564bba520d8e216ae6da374994d8f8b400e"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/pigment-dev/rclone/releases/download/v#{version}/pdrclone_#{version}_linux_arm64.tar.gz"
      sha256 "fa1f80c169b9dd806625517bc6c5752384fad646a19e60a6d38b9c05be1d721c"
    end
    on_intel do
      url "https://github.com/pigment-dev/rclone/releases/download/v#{version}/pdrclone_#{version}_linux_amd64.tar.gz"
      sha256 "b754cbd4ac2e34b89acaaa369ec95b0cc749588e42b6ebd32305e16ebb055062"
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
