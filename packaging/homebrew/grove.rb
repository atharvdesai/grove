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

  # Early builds are not signed with a Developer ID, so macOS Gatekeeper
  # blocks the first launch. Approve it once: System Settings ->
  # Privacy & Security -> Open Anyway. Grove does not strip the quarantine
  # flag for you.

  zap trash: [
    "~/Library/Preferences/app.grove.Grove.plist",
  ]
end
