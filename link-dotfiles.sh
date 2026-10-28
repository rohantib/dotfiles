#!/bin/bash
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

files() {
  find "$PWD" -name .git -prune -o -type f -path "$PWD/.*" "$@"
}

echo "Files to symlink into $HOME:"
files -exec sh -c '
  for src do
    relative="${src#"$PWD"/}"
    printf "%s → ~/%s\n" "$relative" "$relative"
  done
' sh {} +

read -r -p "Continue? [y/N] " answer
[[ "$answer" = [yY] ]] || exit 0

files -exec sh -c '
  for src do
    dest="$HOME/${src#"$PWD"/}"
    if [ -e "$dest" ] || [ -L "$dest" ]; then
      printf "Skipping existing: %s\n" "$dest"
    else
      mkdir -p "$(dirname "$dest")" && ln -sv "$src" "$dest"
    fi
  done
' sh {} +

