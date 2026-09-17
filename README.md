# alpine-pi

Alpine Linux images for the **Raspberry Pi Zero W** (armhf). (happy to add other armhf boards tho)

## Images

| variant | notes |
|---|---|
| `headless` | Fastest. Console only. The network is the only way in, so set your wifi up before first boot (see below). |
| `sway` | Fast, but may be harder if you are not used to tiling managers. sway ships i3's keybindings, so the [i3 User's Guide is prob a good introduction](https://i3wm.org/docs/userguide.html). |
| `xfce4` | Slowest option, but easiest for new users as it's a traditional desktop. |

## Flashing

Download the `.img.xz`, check it against `SHA256SUMS`, then open the `.img.xz` **directly** in [usbimager](https://gitlab.com/bztsrc/usbimager) — no need to unzip it first.

How to check the hash:

- Linux: `sha256sum -c SHA256SUMS`
- macOS: `shasum -a 256 alpinepi-*.img.xz`
- Windows: `certutil -hashfile alpinepi-<variant>.img.xz SHA256`

Any SD card of 4 GB or larger works.

### Credentials

Everything is `alpinepi` — hostname, user, password, Wi-Fi SSID, Wi-Fi passphrase. Change the password on first login using `passwd` in the terminal.

### Wi-Fi

After you flash the SD card, mount it on your computer (easily done by unplugging and replugging your SD card) and edit `wpa_supplicant.conf` on the boot partition.

```
country=US

network={
	ssid="alpinepi"
	psk=<64 hex characters>
	scan_ssid=1
}
```

Change three things:

- `country=` your two-letter country code.
- `ssid="YourNetwork"`: **keep the quotes**.
- `psk="YourPassword"`: **keep the quotes**. Note that the hex is replaced by your password in quotes.

### Rational

Here are the remaining OSes in this space. Everything here has a current ARMv6 build; anything that stopped shipping for this board is left out.

General purpose:

- [DietPi](https://dietpi.com/): a good choice for end users. slightly too slow for my taste (eg. apt). Depends on Raspberry Pi's repositories.
- [Raspberry Pi OS](https://www.raspberrypi.com/software/): default choice for end users, but I tried to test headless mode and it failed. Seems like it's not tested often.
- [Alpine Linux](https://alpinelinux.org/downloads/): quick, but hard for end users to set up.
- [Void Linux](https://repo-default.voidlinux.org/live/current/): hard to set up for end users.
- [Gentoo](https://distfiles.gentoo.org/releases/arm/autobuilds/current-stage3-armv6j_hardfp-openrc/): hard to set up for end users.
- [Buildroot](https://buildroot.org/): hard to set up for end users.
- [Yocto](https://github.com/agherzan/meta-raspberrypi): hard to set up for end users.

Single purpose:

- [OpenWrt](https://downloads.openwrt.org/releases/24.10.0/targets/bcm27xx/bcm2708/): router OS.
- [Batocera](https://batocera.org/): retro gaming
- [Lakka](https://www.lakka.tv/): retro gaming, RetroArch based.
- [Volumio](https://volumio.com/en/get-started): music player
- [piCorePlayer](https://www.picoreplayer.org/): music player
- [OctoPi](https://octoprint.org/download/): 3D printer control
- [MainsailOS](https://docs.mainsail.xyz/): 3D printer control
- [Pwnagotchi](https://github.com/jayofelony/pwnagotchi): wifi handshake collecting
- [Pi-Star](https://www.pistar.uk/): ham radio digital voice hotspot.
- [PiAware](https://flightaware.com/adsb/piaware/build): ADS-B flight tracking.
- [balenaOS](https://github.com/balena-os/balena-raspberrypi): runs containers, managed fleet style.

Not Linux:

- [NetBSD](https://cdn.netbsd.org/pub/NetBSD/NetBSD-11.0/evbarm-earmv6hf/binary/gzimg/): hard to set up for end users.
- [RISC OS](https://www.riscosopen.org/content/downloads/raspberry-pi): not Linux or BSD
- [9front](http://9front.org/iso/): not Linux or BSD
- [9legacy](http://9legacy.org/): not Linux or BSD

Bare metal, if you want to write the whole thing yourself:

- [Circle](https://github.com/rsta2/circle): C++ framework.
- [Ultibo](https://ultibo.org/): Free Pascal framework.
- [RTEMS](https://www.rtems.org/): RTOS with a `raspberrypi` BSP.
- [L4Re / Fiasco.OC](https://github.com/kernkonzept/fiasco): microkernel with an `rpizw` board target. hard to set up for end users

Raspberry Pi Ltd only commits to producing the Zero W ["until at least January 2030"](https://www.raspberrypi.com/products/raspberry-pi-zero-w/), but how long will Raspberry Pi OS keep supporting ARMv6?

This hopes to package up Alpine Linux to:

1. hopefully show there is a userbase for armhf users
2. show that pmbootstrap/pmaports can be used to configure pure Alpine Linux images
3. make an easy-to-use img for end users
4. prevent the raspberry pi zero w (and hopefully other armhf boards) from becoming ewaste

This repo builds with pmbootstrap and pmaports even though postmarketOS [removed armhf (ARMv6)](https://postmarketos.org/edge/2026/06/22/armhf-removed/). The images it produces contain **nothing from postmarketOS**.

Unfortunately, as these forks contain code written with AI, they will not be accepted upstream ([AI policy](https://docs.postmarketos.org/policies-and-processes/development/ai-policy.html)).

- [pmbootstrap](https://github.com/CodebergIsBetter/pmbootstrap)
- [pmaports](https://github.com/CodebergIsBetter/pmaports)
