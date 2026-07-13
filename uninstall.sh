#!/bin/bash
#
# Since: July, 2026
# Author: gvenzl
# Name: uninstall.sh
# Description: Uninstalls the pi-frame service from a Raspberry Pi running Raspberry Pi OS.
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

# Boot volume location
BOOT_DIR="/boot/firmware"
BOOT_DIR_RO=0

#####################################
### UNINSTALL
#####################################

echo "Uninstalling pi-frame..."

echo "Uninstalling pi-frame service..."
systemctl --user stop pi-frame.service pi-frame-ingest.service
systemctl --user disable pi-frame.service pi-frame-ingest.service
rm ~/.config/systemd/user/pi-frame*.service
rm ~/.local/bin/pi-frame-ingest
systemctl --user daemon-reload

# Remove directories if they are empty
rmdir -p --ignore-fail-on-non-empty ~/.config/systemd/user
rmdir -p --ignore-fail-on-non-empty ~/.local/bin

echo "Removing dependencies..."
sudo apt remove -y mpv imagemagick socat

if findmnt -no OPTIONS "$BOOT_DIR" | grep -qw ro; then
  echo "Boot partition is read-only. Remounting as read-write..."
  sudo mount -o remount,rw "$BOOT_DIR"
  BOOT_DIR_RO=1
fi

## Add HDMI settings to config.txt
echo "Removing pi-frame settings from config.txt..."
sudo sed -i '/^hdmi_force_edid_audio=1$/,/^hdmi_timings=1024 1 50 18 50 600 1 15 3 15 0 0 0 60 0 40000000 3\n$/d' $BOOT_DIR/config.txt

## Remount boot partition as read-only if it was originally read-only
if [ "$BOOT_DIR_RO" -eq 1 ]; then
  echo "Remounting boot partition as read-only..."
  sudo mount -o remount,ro "$BOOT_DIR"
fi
