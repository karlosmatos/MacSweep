#!/bin/bash
# Disk cleanup. Bundled in MacSweep.app, which runs it on demand and every Sunday at 10:00.
#   --dry-run       print "<category>\t<bytes>" for what would be removed, change nothing
#   --list <cat>    print "<bytes>\t<path>" for each item of one category, excluded ones too, change nothing
# Categories listed one per line in ~/.config/disk-cleanup/skip are left alone (MacSweep writes it).
# Paths listed one per line in ~/.config/disk-cleanup/exclude are left alone too (MacSweep writes it).
# ~/.config/disk-cleanup/projects lists folders searched for stale project dependencies (MacSweep writes it).
# DISK_CLEANUP_PROGRESS=<file>: the category being cleaned is written there (MacSweep shows it).
# Log: ~/Library/Logs/disk-cleanup/cleanup.log
set -u
export PATH="$HOME/.local/bin:$HOME/.bun/bin:$HOME/.orbstack/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

MODE=run
case "${1:-}" in
  --dry-run) MODE=dry ;;
  --list) MODE=list; LIST_KEY="${2:-}" ;;
esac
LOW_SPACE_GB=25
LOG_DIR="$HOME/Library/Logs/disk-cleanup"
CONFIG_DIR="$HOME/.config/disk-cleanup"
SKIP_FILE="$CONFIG_DIR/skip"
EXCLUDE_FILE="$CONFIG_DIR/exclude"
PROJECTS_FILE="$CONFIG_DIR/projects"
mkdir -p "$LOG_DIR"
[ $MODE = run ] && exec >>"$LOG_DIR/cleanup.log" 2>&1

free_gb() { df -g /System/Volumes/Data | awk 'NR==2 {print $4}'; }
notify() { osascript -e "display notification \"$1\" with title \"MacSweep\""; }
# Total bytes of the NUL-separated paths on stdin.
size_of() { xargs -0 du -sk 2>/dev/null | awk '{s+=$1} END {print s*1024+0}'; }
report() { printf '%s\t%s\n' "$1" "$2"; }
existing() { for p in "$@"; do [ -n "$p" ] && [ -e "$p" ] && printf '%s\0' "$p"; done; }
# Passes on the NUL-separated paths that are not listed in $EXCLUDE_FILE.
not_excluded() {
  if [ -s "$EXCLUDE_FILE" ]; then
    while IFS= read -r -d '' p; do grep -qxF -- "$p" "$EXCLUDE_FILE" || printf '%s\0' "$p"; done
  else
    cat
  fi
}
# Moves the given paths to the Trash (recoverable). NSFileManager via JXA: /usr/bin/trash needs macOS 15.
trash_paths() {
  [ $# -gt 0 ] || return 0
  osascript -l JavaScript -e 'function run(argv) {
    ObjC.import("Foundation")
    argv.forEach(p => {
      const ok = $.NSFileManager.defaultManager.trashItemAtURLResultingItemURLError($.NSURL.fileURLWithPath(p), null, null)
      console.log((ok ? "trashed: " : "failed to trash: ") + p)
    })
  }' "$@"
}
# True when this category should be cleaned now; also announces it to MacSweep.
clean() {
  if grep -qx "$1" "$SKIP_FILE" 2>/dev/null; then echo "skipped: $1"; return 1; fi
  [ -n "${DISK_CLEANUP_PROGRESS:-}" ] && echo "$1" >"$DISK_CLEANUP_PROGRESS"
  return 0
}
# category <key> <paths> <action>: <paths> prints the category's items NUL-separated,
# <action> gets the ones not excluded on stdin. One function serves --dry-run, --list and the real run.
category() {
  case $MODE in
    dry) report "$1" "$($2 | not_excluded | size_of)" ;;
    list) [ "$1" = "$LIST_KEY" ] && $2 | xargs -0 du -sk 2>/dev/null | awk -F'\t' '{printf "%d\t%s\n", $1 * 1024, $2}' ;;
    run) if clean "$1"; then $2 | not_excluded | $3; echo "$1 done"; fi ;;
  esac
  return 0
}

# Actions
remove() { xargs -0 rm -rf; }
# Emptied, not removed, so running apps can keep writing.
empty() { while IFS= read -r -d '' d; do find "$d" -mindepth 1 -maxdepth 1 -exec rm -rf {} +; done; }
to_trash() {
  local files=()
  while IFS= read -r -d '' f; do files+=("$f"); done
  trash_paths ${files[@]+"${files[@]}"}
}

[ $MODE = run ] && echo "=== $(date '+%F %T') start, free: $(free_gb) GB"

# Dev caches: package managers download everything again when needed.
dev_caches() {
  existing "$HOME/.npm/_cacache" "$HOME/.bun/install/cache" "$HOME/.cache/uv" "$HOME/.cache/prisma" \
    "$HOME/.cache/codex-runtimes" "$HOME/Library/Application Support/Google/GoogleUpdater/crx_cache" \
    "$HOME/Library/Caches/pip" "$HOME/Library/Caches/Yarn" "$HOME/Library/pnpm/store" "$HOME/Library/Caches/go-build" \
    "$HOME/Library/Caches/CocoaPods" "$HOME/.gradle/caches" "$HOME/.cargo/registry/cache"
}
category caches dev_caches remove

# Docker build cache, only when Docker (or OrbStack) is running. Not path-based, so it has no --list.
docker_build_cache() {
  docker info >/dev/null 2>&1 || { echo 0; return; }
  docker system df --format '{{.Type}}\t{{.Size}}' 2>/dev/null | LC_ALL=C awk -F'\t' '$1 == "Build Cache" {
    n = $2 + 0; u = $2; sub(/^[0-9.]+/, "", u)
    m = (u == "kB") ? 1e3 : (u == "MB") ? 1e6 : (u == "GB") ? 1e9 : (u == "TB") ? 1e12 : 1
    printf "%.0f", n * m; found = 1
  } END { if (!found) print 0 }'
}
if [ $MODE = dry ]; then
  report docker "$(docker_build_cache)"
elif [ $MODE = run ] && clean docker; then
  docker info >/dev/null 2>&1 && docker builder prune -af >/dev/null 2>&1
  echo "docker done"
fi

# App caches (browsers, Spotify, Electron apps)
app_caches() {
  local dirs=("$HOME/Library/Caches/Google" "$HOME/Library/Caches/Firefox" "$HOME/Library/Caches/BraveSoftware"
    "$HOME/Library/Caches/Microsoft Edge" "$HOME/Library/Caches/com.operasoftware.Opera" "$HOME/Library/Caches/com.spotify.client")
  for app in Slack discord Code Notion; do
    for c in Cache "Code Cache" GPUCache; do dirs+=("$HOME/Library/Application Support/$app/$c"); done
  done
  existing "${dirs[@]}"
}
category app_caches app_caches empty

# Xcode build data, one folder per project
derived_data() {
  local d="$HOME/Library/Developer/Xcode/DerivedData"
  [ -d "$d" ] && find "$d" -mindepth 1 -maxdepth 1 -print0
}
category xcode derived_data remove

# Simulators whose runtime is gone, and device symbols for all but the newest OS version per platform.
# Xcode copies the symbols again the next time a device on that version connects.
simulators() {
  if [ -d "$HOME/Library/Developer/CoreSimulator/Devices" ]; then
    xcrun simctl list devices unavailable 2>/dev/null | grep -oE '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}' |
      while read -r udid; do existing "$HOME/Library/Developer/CoreSimulator/Devices/$udid"; done
  fi
  for d in "$HOME/Library/Developer/Xcode/"*DeviceSupport; do
    [ -d "$d" ] || continue
    find "$d" -mindepth 1 -maxdepth 1 -type d -print0 | xargs -0 stat -f '%m%t%N' | sort -rn | tail -n +2 | cut -f2- |
      while IFS= read -r p; do printf '%s\0' "$p"; done
  done
}
remove_simulators() {
  while IFS= read -r -d '' p; do
    case "$p" in
      */CoreSimulator/Devices/*) xcrun simctl delete "$(basename "$p")" ;;
      *) rm -rf "$p" ;;
    esac
  done
}
category simulators simulators remove_simulators

# Homebrew downloads. brew cleans its own cache, so it has no --list.
if [ $MODE = dry ]; then
  report homebrew "$(existing "$(brew --cache 2>/dev/null)" | size_of)"
elif [ $MODE = run ] && clean homebrew; then
  brew cleanup --prune=all -s >/dev/null 2>&1
  echo "homebrew done"
fi

# Logs older than 30 days
old_logs() { find "$HOME/Library/Logs" -type f -mtime +30 -not -path "$LOG_DIR/*" -print0 2>/dev/null; }
category logs old_logs remove

# Codex sessions older than 30 days
old_sessions() {
  for d in "$HOME/.codex/sessions" "$HOME/.codex/archived_sessions"; do
    [ -d "$d" ] && find "$d" -type f -mtime +30 -print0
  done
}
remove_sessions() {
  remove
  for d in "$HOME/.codex/sessions" "$HOME/.codex/archived_sessions"; do
    [ -d "$d" ] && find "$d" -mindepth 1 -type d -empty -delete
  done
}
category codex old_sessions remove_sessions

# Downloads older than 60 days -> Trash (recoverable)
old_downloads() { find "$HOME/Downloads" -mindepth 1 -maxdepth 1 ! -name '.*' -mtime +60 -print0; }
category downloads old_downloads to_trash

# Rebuildable dependencies (node_modules, Python virtualenvs, Rust target) of projects in the folders
# from $PROJECTS_FILE without file changes for 30 days. The key stays node_modules for existing skip files.
project_dirs() {
  [ -f "$PROJECTS_FILE" ] || return 0
  while IFS= read -r d; do [ -n "$d" ] && [ -d "$d" ] && printf '%s\0' "$d"; done <"$PROJECTS_FILE"
}
is_dependency_dir() {
  case "$(basename "$1")" in
    node_modules) true ;;
    .venv | venv) [ -f "$1/pyvenv.cfg" ] ;;
    target) [ -f "$(dirname "$1")/Cargo.toml" ] ;;
    *) false ;;
  esac
}
stale_dependencies() {
  project_dirs | xargs -0 -I{} find {} -maxdepth 4 -type d \
    \( -name node_modules -o -name .venv -o -name venv -o -name target \) -not -path '*/.next/*' -prune -print0 |
    while IFS= read -r -d '' dep; do
      is_dependency_dir "$dep" || continue
      project=$(dirname "$dep")
      recent=$(find "$project" \( -name node_modules -o -name .venv -o -name venv -o -name target -o -name .git -o -name .next \) -prune \
        -o -type f -mtime -30 -print -quit)
      [ -z "$recent" ] && printf '%s\0' "$dep"
    done
}
category node_modules stale_dependencies remove

[ $MODE = run ] || exit 0

FREE=$(free_gb)
echo "done, free: $FREE GB"

# Low space after the weekly run -> one notification. MacSweep (DISK_CLEANUP_NO_REPORT=1) warns on its own.
if [ -z "${DISK_CLEANUP_NO_REPORT:-}" ] && [ "$FREE" -lt "$LOW_SPACE_GB" ]; then
  notify "Po úklidu zbývá jen ${FREE} GB. Otevři MacSweep, Analýza disku nebo Poradce najde, co dál."
fi
