class Pdrclone < Formula
  desc "Sync daemon and CLI for PigmentDev rClone, powered by rclone"
  homepage "https://pigment.dev/products/rclone/"
  version "1.0.0-beta.3"
  license "MIT"

  on_macos do
    on_arm do
      url "https://github.com/pigment-dev/rclone/releases/download/v#{version}/pdrclone_#{version}_darwin_arm64.tar.gz"
      sha256 "8896b140b708724289ef13542aea9d0cc57a7a509305acc0173284e690435411"
    end
    on_intel do
      url "https://github.com/pigment-dev/rclone/releases/download/v#{version}/pdrclone_#{version}_darwin_amd64.tar.gz"
      sha256 "65c81eb72a2296efa3d8ba9fb14efc5e7cbba13aee04dc9430f7ee06472e2b36"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/pigment-dev/rclone/releases/download/v#{version}/pdrclone_#{version}_linux_arm64.tar.gz"
      sha256 "9657d12f7540441b85218a8a87a92304951830c936bd787cf8d0be818bdc9966"
    end
    on_intel do
      url "https://github.com/pigment-dev/rclone/releases/download/v#{version}/pdrclone_#{version}_linux_amd64.tar.gz"
      sha256 "8f334d8b2693c8b81b2dbadb490da62aa84e4215459efc5d2acc971c8e0e5291"
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
