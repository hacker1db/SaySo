cask "sayso" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/hacker1db/personal-dictation/releases/download/v#{version}/Sayso-v#{version}.zip"
  name "Sayso"
  desc "Local, private push-to-talk dictation in the menu bar"
  homepage "https://github.com/hacker1db/personal-dictation"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on formula: "whisper-cpp"
  depends_on macos: :ventura

  app "Sayso.app"

  uninstall quit: "dev.hacker1db.personal-dictation"

  zap trash: [
    "~/Library/Application Support/Sayso",
    "~/Library/Logs/Sayso.log",
    "~/Library/Preferences/dev.hacker1db.personal-dictation.plist",
  ]

  caveats <<~EOS
    Sayso downloads its local Whisper speech model (about 1.6 GB) on first use.
    Grant Microphone and Accessibility access when prompted.
    Verify a release download with cosign:
      cosign verify-blob --bundle Sayso-v#{version}.zip.sigstore.json \\
        --certificate-identity-regexp '^https://github.com/hacker1db/personal-dictation/' \\
        --certificate-oidc-issuer https://token.actions.githubusercontent.com Sayso-v#{version}.zip
  EOS
end
