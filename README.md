# pi-frame
Pi-Frame - an auto-updating, private picture &amp; video frame using a Raspberry Pi.

Read more about the story at [Turning your Raspberry Pi into a picture and video frame](https://www.geraldonit.com/turning-your-raspberry-pi-into-a-picture-and-video-frame/).

In short, I wanted to have a picture frame that I could easily upload pictures to, but fully locally in my own private network at home. I don't care to send pictures via the phone over 1000s of kilometers away because I just want to use it for home and upload pictures to it while I am at home. I would have even been happy with a frame that takes a USB stick and just circles through the pictures and videos on it but these are almost impossible to find these days and what I found was not quite what I was looking for.

So this is how I turned a Raspberry Pi (4B) into a local, fully private picture and video frame.

# BOM

* [Raspberry Pi Screen, 10.1 Inch Touchscreen Monitor, IPS 1024×600, Dual Built-in Speakers](https://ipistbit.com/products/ipistbit-raspberry-pi-screen-10-1-inch-touchscreen-monitor-ips-1024-600-dual-built-in-speakers-hdmi-portable-monitor-compatible-with-raspberry-pi-5-4-3-zero-driver-free)
* [Raspberry Pi 4B](https://www.raspberrypi.com/products/raspberry-pi-4-model-b/)
* SD card
* USB-C power cable for the Pi
* USB stick

# Installation

Run `install.sh` and follow the input prompts.

The script expects `sudo` privileges for whichever user runs the script, meaning you will have to make sure that the user on the Pi has `sudo` privileges before running it.

```bash
./install.sh
```

# Uninstallation

Run `uninstall.sh` to uninstall Pi-Frame.
