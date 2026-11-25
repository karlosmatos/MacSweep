#!/bin/bash
# Disk cleanup. Bundled in MacSweep.app, which runs it on demand and every Sunday at 10:00.
#   --dry-run   print "<category>\t<bytes>" for what would be removed, change nothing
# Categories listed one per line in ~/.config/disk-cleanup/skip are left alone (MacSweep writes it).
# DISK_CLEANUP_PROGRESS=<file>: the category being cleaned is written there (MacSweep shows it).
# Log: ~/Library/Logs/disk-cleanup/cleanup.log
set -u
export PATH="$HOME/.local/bin:$HOME/.bun/bin:$HOME/.orbstack/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1
LOW_SPACE_GB=25
LOG_DIR="$HOME/Library/Logs/disk-cleanup"
SKIP_FILE="$HOME/.config/disk-cleanup/skip"
mkdir -p "$LOG_DIR"
[ $DRY = 0 ] && exec >>"$LOG_DIR/cleanup.log" 2>&1

free_gb() { df -g /System/Volumes/Data | awk 'NR==2 {print $4}'; }
notify() { osascript -e "display notification \"$1\" with title \"MacSweep\""; }
# Total bytes of the NUL-separated paths on stdin.
size_of() { xargs -0 du -sk 2>/dev/null | awk '{s+=$1} END {print s*1024+0}'; }
report() { printf '%s\t%s\n' "$1" "$2"; }
existing() { for p in "$@"; do [ -n "$p" ] && [ -e "$p" ] && printf '%s\0' "$p"; done; }
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

[ $DRY = 0 ] && echo "=== $(date '+%F %T') start, free: $(free_gb) GB"

# Dev caches
CACHES=("$HOME/.npm/_cacache" "$HOME/.bun/install/cache" "$HOME/.cache/uv" "$HOME/.cache/prisma"
  "$HOME/.cache/codex-runtimes" "$HOME/Library/Application Support/Google/GoogleUpdater/crx_cache")
if [ $DRY = 1 ]; then
  report caches "$(existing "${CACHES[@]}" | size_of)"
elif clean caches; then
  rm -rf "${CACHES[@]}"
  docker info >/dev/null 2>&1 && docker builder prune -af >/dev/null 2>&1
  echo "caches cleaned"
fi

# App caches (Chrome, Spotify). Emptied, not removed, so running apps can keep writing.
APP_CACHES=("$HOME/Library/Caches/Google" "$HOME/Library/Caches/com.spotify.client")
if [ $DRY = 1 ]; then
  report app_caches "$(existing "${APP_CACHES[@]}" | size_of)"
elif clean app_caches; then
  for c in "${APP_CACHES[@]}"; do [ -d "$c" ] && find "$c" -mindepth 1 -maxdepth 1 -exec rm -rf {} +; done
  echo "app caches cleaned"
fi

# Xcode build data
XCODE="$HOME/Library/Developer/Xcode/DerivedData"
if [ $DRY = 1 ]; then
  report xcode "$(existing "$XCODE" | size_of)"
elif clean xcode; then
  rm -rf "$XCODE"
  echo "xcode derived data removed"
fi

# Homebrew downloads
if [ $DRY = 1 ]; then
  report homebrew "$(existing "$(brew --cache 2>/dev/null)" | size_of)"
elif clean homebrew; then
  brew cleanup --prune=all -s >/dev/null 2>&1
  echo "homebrew cleaned"
fi

# Logs older than 30 days
old_logs() { find "$HOME/Library/Logs" -type f -mtime +30 -not -path "$LOG_DIR/*" -print0 2>/dev/null; }
if [ $DRY = 1 ]; then
  report logs "$(old_logs | size_of)"
elif clean logs; then
  old_logs | xargs -0 rm -f
  echo "old logs removed"
fi

# Codex sessions older than 30 days
old_sessions() {
  for d in "$HOME/.codex/sessions" "$HOME/.codex/archived_sessions"; do
    [ -d "$d" ] && find "$d" -type f -mtime +30 -print0
  done
}
if [ $DRY = 1 ]; then
  report codex "$(old_sessions | size_of)"
elif clean codex; then
  old_sessions | xargs -0 rm -f
  for d in "$HOME/.codex/sessions" "$HOME/.codex/archived_sessions"; do
    [ -d "$d" ] && find "$d" -mindepth 1 -type d -empty -delete
  done
  echo "old codex sessions removed"
fi

# Downloads older than 60 days -> Trash (recoverable)
old_downloads() { find "$HOME/Downloads" -mindepth 1 -maxdepth 1 ! -name '.*' -mtime +60 -print0; }
if [ $DRY = 1 ]; then
  report downloads "$(old_downloads | size_of)"
elif clean downloads; then
  files=()
  while IFS= read -r -d '' f; do files+=("$f"); done < <(old_downloads)
  trash_paths ${files[@]+"${files[@]}"}
fi

# node_modules of projects in ~/Github without file changes for 30 days
stale_node_modules() {
  find "$HOME/Github" -maxdepth 4 -type d -name node_modules -not -path '*/.next/*' -prune -print0 |
    while IFS= read -r -d '' nm; do
      project=$(dirname "$nm")
      recent=$(find "$project" \( -name node_modules -o -name .git -o -name .next \) -prune \
        -o -type f -mtime -30 -print -quit)
      [ -z "$recent" ] && printf '%s\0' "$nm"
    done
}
if [ $DRY = 1 ]; then
  report node_modules "$(stale_node_modules | size_of)"
  exit 0
fi
if clean node_modules; then
  stale_node_modules | while IFS= read -r -d '' nm; do rm -rf "$nm" && echo "removed: $nm"; done
fi

FREE=$(free_gb)
echo "done, free: $FREE GB"

# Low space after the weekly run -> one notification. MacSweep (DISK_CLEANUP_NO_REPORT=1) warns on its own.
if [ -z "${DISK_CLEANUP_NO_REPORT:-}" ] && [ "$FREE" -lt "$LOW_SPACE_GB" ]; then
  notify "Po úklidu zbývá jen ${FREE} GB. Otevři MacSweep, Analýza disku nebo Poradce najde, co dál."
fi
