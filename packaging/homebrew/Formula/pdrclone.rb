class Pdrclone < Formula
  desc "Sync daemon and CLI for PigmentDev rClone, powered by rclone"
  homepage "https://pigment.dev/products/rclone/"
  version "1.0.0-beta.13"
  license "MIT"

  on_macos do
    on_arm do
      url "https://github.com/pigment-dev/rclone/releases/download/v#{version}/pdrclone_#{version}_darwin_arm64.tar.gz"
      sha256 "ef77a70641930933b215f93dc064ca13402fae78f2f12e9117c3e66278a0bba5"
    end
    on_intel do
      url "https://github.com/pigment-dev/rclone/releases/download/v#{version}/pdrclone_#{version}_darwin_amd64.tar.gz"
      sha256 "1e491aa4398e25f8616740ba940ef2994318714672f559068dedd21888e1493d"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/pigment-dev/rclone/releases/download/v#{version}/pdrclone_#{version}_linux_arm64.tar.gz"
      sha256 "cbfcffaf060906795b0a61ceff0da03836f28482539dd999b319e26cfcedc588"
    end
    on_intel do
      url "https://github.com/pigment-dev/rclone/releases/download/v#{version}/pdrclone_#{version}_linux_amd64.tar.gz"
      sha256 "5eff18c93cab0552baf0e353aebe3e249d94a6488569aaf45a3f39eeac707e8c"
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
