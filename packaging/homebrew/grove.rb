# Template for the cask in atharvdesai/homebrew-grove. The release workflow
# fills in @VERSION@ and @SHA256@ and pushes it there; install with
#
#   brew install --cask atharvdesai/grove/grove
cask "grove" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/atharvdesai/grove/releases/download/v#{version}/Grove-#{version}.zip"
  name "Grove"
  desc "Meeting notes that listen without joining the call, written on your Mac"
  homepage "https://github.com/atharvdesai/grove"

  depends_on macos: ">= :tahoe"
  depends_on arch: :arm64

  app "Grove.app"

  # Until Grove is signed with a Developer ID, macOS would block the first
  # launch of a downloaded copy. Installing through Homebrew is the user's
  # explicit choice to trust it, so the download flag is cleared here.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Grove.app"]
  end

  zap trash: [
    "~/Library/Preferences/app.grove.Grove.plist",
  ]
end
