class Ocm < Formula
  desc "OpenCode Model Manager - Enterprise-grade model catalog lifecycle management"
  homepage "https://github.com/SunnyJayaRaju/oc-model-manager"
  url "https://github.com/SunnyJayaRaju/oc-model-manager/releases/download/v2.0.0/ocm-2.0.0.tar.gz"
  sha256 "0dbcea57c3eb7e1ea76062972d7160e2c012a58ce43b600daa26cedd2c755cc7"
  license "MIT"
  version "2.0.0"

  depends_on "bash"
  depends_on "jq"
  depends_on "python@3.12"
  depends_on "sqlite"

  def install
    libexec.install "bin", "lib", "config"
    bin.install_symlink libexec/"bin/ocm" => "ocm"
    # Install man page
    man1.install "docs/ocm.1.md" => "ocm.1"
  end

  def caveats
    <<~EOS
      Configuration file: ~/.config/ocm/config.yaml
      Run `ocm config edit` to customize.

      State directory: ~/.local/state/ocm/

      To enable continuous monitoring:
        ocm scheduler install

      Requires OpenCode to be installed and authenticated.
    EOS
  end

  test do
    assert_match "ocm #{version}", shell_output("#{bin}/ocm version")
    assert_match "audit", shell_output("#{bin}/ocm help")
  end
end