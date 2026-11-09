---
title: LittleChef Privacy Policy
---

# LittleChef Privacy Policy

**Last updated: November 9, 2026**

LittleChef ("we", "the app") is designed with privacy as a core principle. This policy explains what data the app handles and how.

## Summary

LittleChef does not collect, transmit, sell, or share any personal information. We have no servers, no analytics, and no advertising partners. Everything you do in the app stays on your device.

## What data the app handles

**Recipes you import or create.** Stored on your device only, using Apple's SwiftData framework. They are not synced or uploaded anywhere, and we have no access to them.

**Ingredient inventory and shopping list.** The ingredients you record as having, and your shopping list, are stored exactly like your recipes: on your device only.

**Profile exports.** **Settings → Export Profile** saves your recipes, inventory, shopping list and settings to a file, wherever you choose to save or send it, such as the Files app or AirDrop. The app makes this file only when you ask, and never sends it anywhere itself. **Import Profile** reads a file you choose.

**Voice and speech.** When you use voice input, audio is captured by the microphone and converted to text. Where that conversion happens depends on which AI mode the cooking session is using:

- *On-device mode (default):* audio is transcribed with Apple's on-device Speech Recognition framework and spoken replies use the iOS voice. Audio never leaves your device. If your device can't recognize speech on-device, voice input is turned off rather than sending audio to Apple's servers.
- *BigBro mode (optional):* audio is sent over your local Wi-Fi network to the Mac you paired with, which transcribes it and synthesizes spoken replies. It does not leave your local network.

In neither case is audio sent to LittleChef or to any third-party server.

**Recipe photos.** When you import a recipe by photo, the image is processed locally using Apple's Vision framework for OCR. Images are not uploaded anywhere.

**AI inference.**

- *On-device mode (default):* A PrismML Bonsai model runs entirely on your iPhone or iPad using Apple's MLX framework. Which model depends on your device's memory, and devices with enough memory can choose the larger Bonsai 2 27B in Settings. No prompts or responses leave the device. Model weights are downloaded from Hugging Face's public model repository when you choose to download them in Settings. As with any download, Hugging Face can see the request, including your IP address. Nothing about you or your recipes is sent.
- *BigBro mode (optional):* If you choose to pair LittleChef with a Mac running the BigBro companion app on your local network, prompts and responses — and, when you use voice, the recorded audio — are sent over your local Wi-Fi network to that Mac for processing. That includes the text of a recipe you import when the app uses AI to structure it. None of it leaves your local network.

The **Suggested** recipe filter works the same way: to rank your recipes it gives the AI their titles, tags and cooking times, what each is missing from your inventory, and the current day and time. That goes to the on-device model or your paired Mac, depending on the mode, and nowhere else.

The mode is fixed for the duration of a cooking session: it is chosen before you start cooking and cannot change partway through.

**Recipe URL imports.** When you import a recipe from a URL, the app fetches the page directly from that website using the standard iOS web view. The destination website may log the request as it would any normal browser visit, subject to that site's own privacy policy.

## Data we do not collect

- No account or sign-up is required, and we do not collect names, emails, phone numbers, or device identifiers.
- No analytics, telemetry, crash reporting, or usage tracking.
- No advertising or third-party SDKs.
- No location data.

## Permissions

- **Microphone** — required for voice questions while cooking.
- **Speech Recognition** — required to convert your voice to text on-device. Not used in BigBro mode, where the paired Mac transcribes instead.
- **Local Network** — used only to discover an optional Mac running BigBro on your home network. No connections are made without your pairing.
- **Notifications** — used only for timer completion alerts.
- **Photos** — recipe photos are chosen with the system photo picker, which gives the app only the photos you select. No photo library permission is needed, and the photos are processed on-device.

You can revoke any of these permissions at any time in iOS Settings.

## Children

LittleChef is not directed at children under 13 and does not knowingly collect any information from anyone of any age.

## Data deletion

You can delete your data at any time from **Settings → Delete All Data** in the app. This removes your recipes, ingredient inventory, shopping list and settings, downloaded AI models, and paired Macs. Deletion can't be undone.

Uninstalling the app removes everything it stored on that device. A profile you exported is a file you keep, and stays wherever you saved it until you delete it.

## Changes

If this policy ever changes, the updated version will be posted at this URL with a new "Last updated" date.

## Contact

Questions: the.cedster@gmail.com
