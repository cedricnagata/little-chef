---
title: LittleChef Support
---

# LittleChef Support

Questions, problems or ideas: email **the.cedster@gmail.com**, or open an issue on [GitHub](https://github.com/cedricnagata/little-chef/issues).

## Getting started

- **Download a model for on-device AI.** Go to **Settings → AI Provider** and tap **Download**. The size is shown first (about 3.5 GB for Bonsai 8B on an iPhone with 6 GB of RAM or more), with a warning on cellular. After the download, the assistant works without internet.
- **Or use a Mac instead.** Install [BigBro](https://github.com/cedricnagata/bigbro/releases) on a Mac with Apple Silicon (macOS 14 or later), choose BigBro in **Settings → AI Provider**, and approve the pairing on the Mac. The Mac and iPhone must be on the same network. Nothing is downloaded to the iPhone.
- **Without either,** recipe websites that publish structured recipe data still import, and timers can be set by hand.

## Common questions

**Which model does my iPhone get?** It depends on the device's memory: Bonsai 8B with 6 GB or more, Bonsai 4B with 4 GB, Bonsai 1.7B with 3 GB. Only Bonsai 8B (and Bonsai 27B, on devices that can load it, or through BigBro) can set timers and change recipes for you; the smaller models answer questions.

**Voice isn't working.** LittleChef asks for the microphone and speech recognition the first time you use voice. If you declined, turn them on in iOS **Settings → LittleChef**.

**My recipes aren't on my other device.** Recipes, preferences, inventory and the shopping list sync through your private iCloud database. Check that both devices are signed in to the same iCloud account, with iCloud allowed for LittleChef (iOS **Settings → [your name] → iCloud**), and give it a few minutes.

**The Mac doesn't show up.** BigBro must be running, and macOS must have been allowed Local Network access for it (asked on first launch). On the iPhone, check **Settings → LittleChef → Local Network**.

**How do I delete my data?** **Settings → Delete All Data** in the app. It removes your recipes, inventory, shopping list, settings, downloaded models and paired Macs, and with iCloud sync on, the same data from iCloud and your other devices. It can't be undone.

## Privacy

No accounts, analytics or tracking. See the [privacy policy](privacy).
