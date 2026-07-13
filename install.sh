#!/bin/bash
#
# Since: July, 2026
# Author: gvenzl
# Name: install.sh
# Description: Installs the pi-frame service on a Raspberry Pi running Raspberry Pi OS.
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
# SOFTWARE.

# Exit on errors
set -euo pipefail

#####################################
### GLOBAL VARIABLES
#####################################

# Picture frame display settings
DISPLAY_DURATION_SEC=180
DISPLAY_LOCATION="/media/$USER/"
DISPLAY_MAX_WIDTH_PX=1024
DISPLAY_MAX_HEIGHT_PX=600
# Picture frame ingest settings
INGEST_POLL_INTERVAL_SEC=60
INGEST_LOCATIONS="$HOME/Pictures"

# Boot volume location
BOOT_DIR="/boot/firmware"
BOOT_DIR_RO=0

# Pi-frame display settings for config.txt
# Specific to attached HDMI display. Adjust as needed for your display.
PICTURE_FRAME_SETTINGS="hdmi_force_edid_audio=1
max_usb_current=1
hdmi_force_hotplug=1
config_hdmi_boost=7
hdmi_group=2
hdmi_mode=87
hdmi_drive=2
display_rotate=0
hdmi_timings=1024 1 50 18 50 600 1 15 3 15 0 0 0 60 0 40000000 3
"

#####################################
### User variables
#####################################

# pi-frame image location
## Get full path of the first mounted media device (e.g., USB drive) for default display location
DISPLAY_LOCATION=/media/$USER/$(ls /media/$USER | head -n 1)
read -p "Enter the location of the images to be put and displayed (default: $DISPLAY_LOCATION): " user_display_location
if [[ -n "$user_display_location" ]]; then
  DISPLAY_LOCATION="$user_display_location"
fi
# Check if the specified display location exists
if [[ ! -d "$DISPLAY_LOCATION" ]]; then
  echo "Location $DISPLAY_LOCATION does not exist. Please create it or specify a different location."
  exit 1
fi

# pi-frame display duration
read -p "Enter the duration (in seconds) for each image to be displayed (default: $DISPLAY_DURATION_SEC): " user_duration
if [[ -n "$user_duration" ]]; then
  DISPLAY_DURATION_SEC="$user_duration"
fi

## pi-frame ingest location
read -p "Enter the ingest location(s) (comma-separated) for the images (default: $INGEST_LOCATIONS): " user_ingest_location
if [[ -n "$user_ingest_location" ]]; then
  INGEST_LOCATIONS="$user_ingest_location"
fi
# Check if the specified ingest locations exists
while IFS= read -r ingest_location; do
  if [[ ! -d "$ingest_location" ]]; then
    echo "Location $ingest_location does not exist. Please create it or specify a different location."
    exit 1
  fi
done < <(printf '%s\n' "$INGEST_LOCATIONS" | tr ',' '\n')

# ingest poll interval
read -p "Enter the poll interval (in seconds) for checking new images (default: $INGEST_POLL_INTERVAL_SEC): " user_poll_interval
if [[ -n "$user_poll_interval" ]]; then
  INGEST_POLL_INTERVAL_SEC="$user_poll_interval"
fi

#####################################
### Setup and installation
#####################################

# Set pi-frame resolution
## Checking whether boot partition is read-only
if findmnt -no OPTIONS "$BOOT_DIR" | grep -qw ro; then
  echo "Boot partition is read-only. Remounting as read-write..."
  sudo mount -o remount,rw "$BOOT_DIR"
  BOOT_DIR_RO=1
fi

## Comment out dtoverlay=vc4-kms-v3d
## This causes the Pi to no longer boot to the graphical interface
## On Raspberry Pi OS Bookworm, the desktop environment runs on Wayland via labwc,
## and that compositor requires the KMS/DRM graphics driver — which is exactly what vc4-kms-v3d provides.
#echo "Disabling vc4-kms-v3d overlay in config.txt..."
#sudo sed -i 's/^dtoverlay=vc4-kms-v3d/#dtoverlay=vc4-kms-v3d/g' /boot/firmware/config.txt

## Add HDMI settings to config.txt
echo "Adding pi-frame settings to config.txt..."
echo "$PICTURE_FRAME_SETTINGS" | sudo tee -a /boot/firmware/config.txt > /dev/null

## Remount boot partition as read-only if it was originally read-only
if [ "$BOOT_DIR_RO" -eq 1 ]; then
  echo "Remounting boot partition as read-only..."
  sudo mount -o remount,ro "$BOOT_DIR"
fi

# Installing required packages
echo "Installing required packages..."
sudo apt install -y mpv imagemagick ffmpeg socat cifs-utils

# Creating services
echo "Creating user services..."
mkdir -p ~/.config/systemd/user

## Creating pi-frame service
echo "Creating pi-frame service..."
echo "#
# Runs an mpv fullscreen image slideshow on the directly-attached
# HDMI touchscreen display. Points only at the local display folder,
# which is populated and maintained by pi-frame-ingest.service.
#
# --idle=yes keeps mpv open and waiting even if the display folder
# is empty on first boot. Files appended via IPC by the ingest
# service will appear immediately without restarting mpv.
#
# Quitting mpv via touch (clean exit, code 0) will NOT auto-restart
# it. Use 'systemctl --user start pi-frame' to bring it back.
# Crashes restart automatically.
#
# Install:
#   mkdir -p ~/.config/systemd/user
#   cp pi-frame.service ~/.config/systemd/user/
#   systemctl --user daemon-reload
#   systemctl --user enable --now pi-frame.service
#
# Useful commands:
#   systemctl --user status pi-frame
#   systemctl --user stop pi-frame
#   systemctl --user start pi-frame
#   systemctl --user disable pi-frame    # stop starting on login

[Unit]
Description=Pi-Frame - display
After=default.target
# Start the ingest service alongside mpv. Ingest has no display
# dependency so it doesn't belong under graphical-session.target
# directly - owning it here avoids an ordering cycle.
Wants=pi-frame-ingest.service

[Service]
Type=simple

# Small buffer to let the Wayland compositor settle
# and USB/network drives mount before mpv
# tries to open a fullscreen window
ExecStartPre=/bin/sleep 8

# Remove any stale socket left over from a previous run. mpv will
# not overwrite an existing socket file, so without this a crash
# leaves a dead socket that silently disables IPC on restart.
# The leading - means systemd ignores failure (i.e. file not found).
ExecStartPre=-/bin/rm -f /tmp/pi-frame.socket

# Adjust display folder path to match your setup.
# This should be a locally mounted folder - never point mpv at the raw input
# device (USB/network). The ingest service populates this folder.
ExecStart=mpv \
  --gpu-api=opengl \
  --vd=h264_v4l2m2m \
  --fs \
  --idle=yes \
  --loop-playlist=inf \
  --image-display-duration=$DISPLAY_DURATION_SEC \
  --shuffle \
  --input-ipc-server=/tmp/pi-frame.socket \
  $DISPLAY_LOCATION

# Restart on crash only. Clean quit (e.g. via touch) stays stopped.
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target" > ~/.config/systemd/user/pi-frame.service

## Creating pi-frame-ingest service
echo "Creating pi-frame-ingest service..."
mkdir -p ~/.local/bin
cp pi-frame-ingest.sh ~/.local/bin/pi-frame-ingest
chmod +x ~/.local/bin/pi-frame-ingest

echo "#
# Polls an input location on a fixed interval for new image files.
# Resizes each one to fit the display, moves it to the local display
# folder, and notifies mpv via IPC so the new image appears in the
# running slideshow immediately.
#
# Polling is used rather than inotify because inotify does not receive
# change events reliably over NFS.
#
# Also does a sweep of the input folder on startup so any files
# that arrived while the Pi was off are processed right away.
#
# If mpv isn't running when a file arrives, the file still lands
# in the display folder and will appear on next mpv start.
#
# Requires: socat imagemagick
#   sudo apt install -y socat imagemagick
#
# Install:
#   cp pi-frame-ingest.service ~/.config/systemd/user/
#   systemctl --user daemon-reload
#   systemctl --user enable --now pi-frame-ingest.service
#
# Useful commands:
#   systemctl --user status pi-frame-ingest

[Unit]
Description=Pi-Frame - image ingest and resize
# Start after pi-frame so the IPC socket is available for
# live-appending. Wants= rather than Requires= so this service
# keeps running even if mpv is intentionally stopped.
After=pi-frame.service
Wants=pi-frame.service

[Service]
Type=simple

# Arguments: <input_dir> <display_dir> <socket> <max_dimension> <poll_interval_seconds>
# Adjust all five to match your setup.
ExecStart=$HOME/.local/bin/pi-frame-ingest \
  $INGEST_LOCATIONS \
  $DISPLAY_LOCATION \
  /tmp/pi-frame.socket \
  $DISPLAY_MAX_WIDTH_PX \
  $DISPLAY_MAX_HEIGHT_PX \
  $INGEST_POLL_INTERVAL_SEC

# Always restart - if the poll loop exits for any reason bring it
# back automatically
Restart=always
RestartSec=5" > ~/.config/systemd/user/pi-frame-ingest.service

# Enabling services
echo "Enabling services..."
systemctl --user daemon-reload
systemctl --user enable pi-frame.service pi-frame-ingest.service

# Reboot the system to apply changes
echo "Rebooting the system to apply changes..."
sudo reboot
