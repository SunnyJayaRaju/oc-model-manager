class Ocprobe < Formula
  desc "OpenCode Model Probe - Enterprise-grade model catalog lifecycle management"
  homepage "https://github.com/SunnyJayaRaju/oc-model-manager"
  url "https://github.com/SunnyJayaRaju/oc-model-manager/releases/download/v2.0.0/ocprobe-2.0.0.tar.gz"
  sha256 "0dbcea57c3eb7e1ea76062972d7160e2c012a58ce43b600daa26cedd2c755cc7"
  license "MIT"
  version "2.0.0"

  depends_on "bash"
  depends_on "jq"
  depends_on "python@3.12"
  depends_on "sqlite"

  def install
    libexec.install "bin", "lib", "config"
    bin.install_symlink libexec/"bin/ocprobe" => "ocprobe"
    # Install man page
    man1.install "docs/ocprobe.1" => "ocprobe.1"
  end

  def caveats
    <<~EOS
      Configuration file: ~/.config/ocprobe/config.yaml
      Run `ocprobe config edit` to customize.

      State directory: ~/.local/state/ocprobe/

      To enable continuous monitoring:
        ocprobe scheduler install

      Requires OpenCode to be installed and authenticated.
    EOS
  end

  test do
    assert_match "ocprobe #{version}", shell_output("#{bin}/ocprobe version")
    assert_match "audit", shell_output("#{bin}/ocprobe help")
  end
end