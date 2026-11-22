#!/bin/bash
# Copies every Homebrew dylib the app links (and ggml's runtime backend plugins) into
# Contents/Frameworks and rewrites load paths to @rpath, so the app is self-contained.
set -euo pipefail
app="$1"
exe="$app/Contents/MacOS/Sayso"
fw="$app/Contents/Frameworks"
brew_prefix="$(brew --prefix)"
rm -rf "$fw"; mkdir -p "$fw"

# Non-system dependencies of a Mach-O file, one per line.
deps() { otool -L "$1" | tail -n +2 | awk '{print $1}' | grep -E "^($brew_prefix|@rpath/)" || true; }

# Resolve a dependency reference from file $2 to a real path.
resolve() {
  case "$1" in
    @rpath/*) local name="${1#@rpath/}"
      for d in "$brew_prefix/opt/ggml/lib" "$brew_prefix/opt/whisper.cpp/lib" "$brew_prefix/lib" "$(dirname "$2")"; do
        [[ -e "$d/$name" ]] && { echo "$d/$name"; return; }
      done
      echo "bundle-libs: cannot resolve $1 (from $2)" >&2; exit 1 ;;
    *) echo "$1" ;;
  esac
}

# Copy a library (and its dependencies, recursively) into Frameworks.
copy_lib() {
  local src="$1" name; name="$(basename "$1")"
  [[ -e "$fw/$name" ]] && return
  cp -L "$src" "$fw/$name"; chmod u+w "$fw/$name"
  install_name_tool -id "@rpath/$name" "$fw/$name" 2>/dev/null
  local real; real="$(realpath "$src")"
  for dep in $(deps "$real"); do copy_lib "$(resolve "$dep" "$real")"; done
}

# Rewrite every non-system load command in $1 to @rpath/<basename>.
relink() {
  for dep in $(deps "$1"); do
    install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$1" 2>/dev/null
  done
}

for dep in $(deps "$exe"); do copy_lib "$(resolve "$dep" "$exe")"; done
# Backend plugins are dlopen()ed by ggml_backend_load_all_from_path, so otool cannot see them.
for plugin in "$(realpath "$brew_prefix/opt/ggml")"/libexec/libggml-*.so; do copy_lib "$plugin"; done

relink "$exe"
for lib in "$fw"/*; do
  relink "$lib"
  install_name_tool -add_rpath @loader_path "$lib" 2>/dev/null || true
done

# Fail the build if anything still points at Homebrew.
for f in "$exe" "$fw"/*; do
  if otool -L "$f" | tail -n +2 | grep -q "$brew_prefix"; then
    echo "bundle-libs: $f still links Homebrew:" >&2; otool -L "$f" >&2; exit 1
  fi
done
echo "Bundled $(ls "$fw" | wc -l | tr -d ' ') libraries into $fw"
