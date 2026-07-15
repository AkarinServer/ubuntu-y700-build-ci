#!/usr/bin/env bash
set -euo pipefail

ci_log() {
  printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"
}

ci_die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

ci_require_cmd() {
  command -v "$1" >/dev/null 2>&1 || ci_die "required command not found: $1"
}

ci_bool() {
  case "${1:-}" in
    1|yes|true|on) return 0 ;;
    *) return 1 ;;
  esac
}

ci_abs_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$(pwd -P)" "$1" ;;
  esac
}

ci_retry() {
  local max_attempts=$1
  local base_delay=$2
  local attempt=1
  local status
  shift 2

  while true; do
    if "$@"; then
      return 0
    else
      status=$?
    fi
    if [ "$attempt" -ge "$max_attempts" ]; then
      ci_log "command failed after $attempt attempts: $*"
      return "$status"
    fi
    ci_log "command failed (attempt $attempt/$max_attempts); retrying in $((base_delay * attempt)) seconds: $*"
    sleep $((base_delay * attempt))
    attempt=$((attempt + 1))
  done
}

ci_download() {
  local src=$1
  local dst=$2
  local tmp
  case "$src" in
    http://*|https://*)
      ci_require_cmd curl
      tmp="${dst}.part"
      rm -f "$tmp"
      if ! curl \
        --fail \
        --location \
        --ipv4 \
        --retry 8 \
        --retry-all-errors \
        --retry-delay 3 \
        --retry-max-time 300 \
        --connect-timeout 20 \
        --speed-time 60 \
        --speed-limit 1024 \
        --output "$tmp" \
        "$src"; then
        rm -f "$tmp"
        return 1
      fi
      mv "$tmp" "$dst"
      ;;
    '')
      ci_die "empty download source for $dst"
      ;;
    *)
      cp -a "$src" "$dst"
      ;;
  esac
}

ci_extract_archive() {
  local archive=$1
  local dest=$2
  mkdir -p "$dest"

  case "$archive" in
    *.tar.gz|*.tgz) tar -C "$dest" -xzf "$archive"; return ;;
    *.tar.xz) tar -C "$dest" -xJf "$archive"; return ;;
    *.tar.zst) tar -C "$dest" --zstd -xf "$archive"; return ;;
    *.tar) tar -C "$dest" -xf "$archive"; return ;;
    *.zip) ci_require_cmd unzip; unzip -q "$archive" -d "$dest"; return ;;
    *.7z|*.7z.001) ci_require_cmd 7z; 7z x "$archive" -o"$dest" >/dev/null; return ;;
  esac

  # Download URLs often land in extensionless temp files; detect by content.
  if tar -tf "$archive" >/dev/null 2>&1; then
    tar -C "$dest" -xf "$archive"
    return
  fi

  if command -v 7z >/dev/null 2>&1 && 7z l "$archive" >/dev/null 2>&1; then
    7z x "$archive" -o"$dest" >/dev/null
    return
  fi

  ci_die "unsupported archive format: $archive"
}
