#!/bin/bash
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

# Directories linked whole, so new files in them are picked up automatically.
# Everything else is linked file by file.
DIRS=(.config/rex)

targets() {
  printf '%s/\n' "${DIRS[@]}"
  prune=()
  for dir in "${DIRS[@]}"; do prune+=(-path "./$dir" -prune -o); done
  find . -name .git -prune -o "${prune[@]}" -type f -path './.*' -print | sed 's|^\./||'
}

echo "Symlinks to create in $HOME:"
targets | sed 's|.*|~/& → &|'

read -r -p "Continue? [y/N] " answer
[[ "$answer" = [yY] ]] || exit 0

targets | while read -r target; do
  target="${target%/}"
  dest="$HOME/$target"
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    echo "Skipping existing: $dest"
  else
    mkdir -p "$(dirname "$dest")" && ln -sv "$PWD/$target" "$dest"
  fi
done
