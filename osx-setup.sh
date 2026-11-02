# Command-line tools
brew install antidote direnv fzf

# Apps
brew install --cask \
  slack \
  rectangle \
  ghostty \
  notion \
  tailscale \
  claude \
  chatgpt \
  spotify

# Node
curl -fsSL https://fnm.vercel.app/install | bash
fnm install --lts

# OSX Settings
defaults write -g NSAutomaticSpellingCorrectionEnabled -bool false
defaults write -g NSAutomaticCapitalizationEnabled -bool false
defaults write -g NSAutomaticCapitalizationEnabled -bool false
defaults write com.apple.dock autohide -bool true

