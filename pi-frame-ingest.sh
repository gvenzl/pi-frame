#!/bin/bash
#
# Since: July, 2026
# Author: gvenzl
# Name: pi-frame-ingest.sh
# Description: Ingests images and videos for the pi-frame display.
#
# Called by pi-frame-ingest.service.
#
# 1. Sweeps the input folder on startup and processes any files
#    already waiting there.
# 2. Then polls the input folder on a fixed interval for new arrivals.
#
# Polling is used instead of inotify because inotify does not receive
# change events reliably over NFS - the kernel watches local inodes,
# not remote filesystem activity.
#
# For each image found:
#   - Moves it locally, resizes it to fit within MAX_WIDTH_PXxMAX_HEIGHT_PX
#     (only shrinks, never upscales) to stay within the Pi 4's GPU
#     texture limit, then moves it to the display folder
#   - Notifies mpv via IPC socket so it appears in the live playlist
#     immediately, without restarting mpv
#
# For each video found:
#   - Moves it directly to the display folder (no resize - the Pi 4
#     hardware decoder handles video natively at any resolution)
#   - Notifies mpv via IPC socket
#
# If a file fails to process (e.g. it is still being written to the
# NFS share when the poll fires), it is returned to the input folder
# and will be retried on the next poll cycle automatically.
#
# Usage (normally called by systemd, not directly):
#   ./pi-frame-ingest.sh <input_dirs> <display_dir> <socket> <max_width_px> <max_height_px> [poll_interval_seconds]
#
# Requires: imagemagick socat
#   sudo apt install -y imagemagick socat
#
# Copyright (c) 2026 Gerald Venzl
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE

set -uo pipefail

INPUT_DIRS="${1:?Usage: $0 <input_dirs> <display_dir> <socket> <max_width_px> <max_height_px> [poll_interval]}"
DISPLAY_DIR="${2:?Usage: $0 <input_dirs> <display_dir> <socket> <max_width_px> <max_height_px> [poll_interval]}"
SOCKET="${3:?Usage: $0 <input_dirs> <display_dir> <socket> <max_width_px> <max_height_px> [poll_interval]}"
MAX_WIDTH_PX="${4:-1024}"
MAX_HEIGHT_PX="${5:-600}"
POLL_INTERVAL="${6:-30}"

###########################
### Helpers
###########################
is_image() {
  # Verifies whether the input file is an image file based on its extension.
  # Returns 0 if it is an image, 1 otherwise.
  case "$1" in
    *.jpg|*.JPG|*.jpeg|*.JPEG|\
    *.png|*.PNG|\
    *.gif|*.GIF|\
    *.bmp|*.BMP|\
    *.heic|*.HEIC) return 0 ;;
    *) return 1 ;;
  esac
}

is_video() {
  # Verifies whether the input file is a video file based on its extension.
  # Returns 0 if it is a video, 1 otherwise.
  case "$1" in
    *.mp4|*.MP4|\
    *.mov|*.MOV|\
    *.mkv|*.MKV|\
    *.avi|*.AVI|\
    *.m4v|*.M4V|\
    *.wmv|*.WMV|\
    *.webm|*.WEBM|\
    *.ts|*.TS|\
    *.mts|*.MTS) return 0 ;;
    *) return 1 ;;
  esac
}

is_media() {
  # Checks if the file is either an image or a video.
  is_image "$1" || is_video "$1"
}

notify_mpv() {
  # Notifies the mpv player via its IPC socket to load a new file into its playlist.
  # Arguments: <filepath>
  local filepath="$1"
  local err rc

  if [ ! -S "$SOCKET" ]; then
    echo "  -> mpv socket not available; file will appear on next mpv start"
    return 0
  fi

  # Redirect stdout to /dev/null (we don't need mpv's JSON reply) and
  # capture stderr so we can give a specific message on failure.
  # Note the order: 2>&1 runs before 1>/dev/null so stderr is captured
  # in the subshell before stdout is discarded.
  err=$(echo "{\"command\": [\"loadfile\", \"$filepath\", \"append-play\"]}" \
    | socat - "$SOCKET" 2>&1 1>/dev/null)
  rc=$?

  if [ $rc -eq 0 ]; then
    echo "  -> $filepath appended to mpv playlist"
  else
    case "$err" in
      *"Connection refused"*)
        # Socket file exists but nothing is listening - stale socket
        # from a previous mpv crash. The ExecStartPre in pi-frame.service
        # removes it on restart, so this resolves itself automatically.
        echo "  -> mpv socket is stale (connection refused); file will appear on next mpv start" >&2
        ;;
      *"No such file"*)
        # Socket was removed between our -S check and the socat call
        echo "  -> mpv socket disappeared; file will appear on next mpv start" >&2
        ;;
      *)
        echo "  -> socat error (rc=$rc): $err" >&2
        ;;
    esac
  fi
}

process_file() {
  # Processes a single media file: moves it to a temporary location,
  # resizes if it's an image, and then moves it to the display folder.
  local src="$1"
  local filename
  filename=$(basename "$src")
  local tmp="$DISPLAY_DIR/.ingest_${filename}"
  local dest="$DISPLAY_DIR/$filename"

  echo "Ingesting: $filename"

  # Move from the NFS share to a local temp name first. The .ingest_
  # prefix keeps it hidden from mpv while it is being processed.
  # Doing this before resizing means magick runs on local storage
  # rather than reading and writing across the network.
  # Note: mv across filesystems is a copy+delete, so the source file
  # is removed from NFS as soon as the local copy is complete.
  if ! mv -- "$src" "$tmp"; then
    echo "  ERROR: could not move $filename from $src" >&2
    return 1
  fi

  # Images are resized locally to fit within MAX_WIDTH_PXxMAX_HEIGHT_PX.
  if is_image "$tmp"; then
    if ! magick "$tmp" -resize "${MAX_WIDTH_PX}x${MAX_HEIGHT_PX}>" "$dest" 2>/dev/null; then
      echo "  ERROR: magick failed on $filename - returning to $src for retry" >&2
      # Move the temp back to the input dir so the next poll cycle will
      # pick it up and try again. This handles the case where the file
      # was still being written to the NFS share when the poll fired.
      if ! mv -- "$tmp" "$src"; then
        echo "  ERROR: could not return $filename to $src - discarding" >&2
        rm -f -- "$tmp"
      fi
      return 1
    else
      # Remove the temp file after successful conversion
      rm -f -- "$tmp"
    fi
  elif is_video "$tmp"; then
    # Get video colors and convert HLG/BT.2020 HDR colors into standard BT.709 SDR
    transfer=$(
      ffprobe -v error \
        -select_streams v:0 \
        -show_entries stream=color_transfer \
        -of default=noprint_wrappers=1:nokey=1 \
        -- "$tmp"
    )

    case "$transfer" in
      arib-std-b67|smpte2084)
        echo "HDR video detected: $transfer"
        video_filter="zscale=transfer=linear:npl=100,format=gbrpf32le,zscale=primaries=bt709,tonemap=hable:desat=0,zscale=transfer=bt709:matrix=bt709:range=tv,scale=${MAX_WIDTH_PX}:${MAX_HEIGHT_PX}:force_original_aspect_ratio=decrease:force_divisible_by=2,format=yuv420p"
        ;;
      *)
        echo "SDR or unknown video: ${transfer:-not tagged}"
        video_filter="scale=${MAX_WIDTH_PX}:${MAX_HEIGHT_PX}:force_original_aspect_ratio=decrease:force_divisible_by=2,format=yuv420p"
        ;;
    esac
    # ffmpeg doesn't support in-file conversion so it already takes care of the desitionation file, we just need to remove the temp file.
    if ! ffmpeg -nostdin \
           -i "$tmp" \
           -y \
           -vf "$video_filter" \
           -c:v libx264 \
           -crf 23 \
           -preset medium \
           -pix_fmt yuv420p \
           -c:a aac \
           -b:a 192k \
           -movflags +faststart \
           "$dest" 2>/dev/null; then
      echo "  ERROR: ffmpeg failed on $filename - returning to $src for retry" >&2
      if ! mv -- "$tmp" "$src"; then
        echo "  ERROR: could not return $filename to $src - discarding" >&2
        rm -f -- "$tmp"
      fi
      # Delete destination file if ffmpeg failed, to avoid leaving a corrupted file in the display folder.
      rm -f -- "$dest"
      return 1
    else
      # Remove old temp file after successful conversion
      rm -f -- "$tmp"
    fi
  else
    echo "  Info: $filename is neither image nor video - discarding" >&2
    rm -f -- "$tmp"
    return 1
  fi

  # Adding the file to mpv's playlist via IPC socket so it appears in the live slideshow immediately.
  notify_mpv "$dest"
}

####################################
### Startup
####################################

echo "============================================"
echo "Pi Frame ingest starting"
echo "  Input:      $INPUT_DIRS"
echo "  Display:    $DISPLAY_DIR"
echo "  Socket:     $SOCKET"
echo "  Max width:  ${MAX_WIDTH_PX}"
echo "  Max height: ${MAX_HEIGHT_PX}"
echo "  Poll:       every ${POLL_INTERVAL}s"
echo "============================================"

#####################################################################
### Initial sweep - handle files that arrived while the Pi was off
#####################################################################

echo "Sweeping input folder for existing files..."
sweep_count=0

# Loop through all input directories.
while IFS= read -r input_dir; do
  while IFS= read -r -d '' f; do
    if is_media "$f"; then
      process_file "$f"
      sweep_count=$((sweep_count + 1))
    fi
  done < <(find "$input_dir" -maxdepth 1 -type f -print0 | sort -z)
done < <(printf '%s\n' "$INPUT_DIRS" | tr ',' '\n')

echo "Sweep complete: $sweep_count file(s) processed."
echo ""

#############################################################
### Poll loop - check for new arrivals on a fixed interval
#############################################################

echo "Polling $INPUT_DIRS every ${POLL_INTERVAL}s..."

while true; do
  sleep "$POLL_INTERVAL"

  # Loop through all input directories.
  while IFS= read -r input_dir; do
    # Loop through all files in the input directory, sorted by name, and process each one.
    # The find command uses -print0 to handle filenames with spaces or special characters,
    # and read -d '' reads until the null character.
    while IFS= read -r -d '' f; do
      is_media "$f" && process_file "$f"
    done < <(find "$input_dir" -maxdepth 1 -type f -print0 | sort -z)
  done < <(printf '%s\n' "$INPUT_DIRS" | tr ',' '\n')

done
