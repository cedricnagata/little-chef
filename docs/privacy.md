---
title: LittleChef Privacy Policy
---

# LittleChef Privacy Policy

**Last updated: May 8, 2026**

LittleChef ("we", "the app") is designed with privacy as a core principle. This policy explains what data the app handles and how.

## Summary

LittleChef does not collect, transmit, sell, or share any personal information. We have no servers, no analytics, and no advertising partners. Everything you do in the app stays on your device or in your own private iCloud account.

## What data the app handles

**Recipes you import or create.** Stored locally on your device using Apple's SwiftData framework. If you have iCloud enabled, recipes also sync to your personal private iCloud database so they appear on your other devices. We have no access to this data — it is encrypted and visible only to you.

**Voice and speech.** By default, audio captured by the microphone is converted to text using Apple's on-device Speech Recognition framework and never leaves your device. If you turn on "Use BigBro for voice" in Settings — which requires pairing with your own Mac first — recordings of what you say are sent over your local Wi-Fi network to that Mac, which transcribes them and speaks the reply back. Audio is never sent to LittleChef or any third-party server in either case.

**Recipe photos.** When you import a recipe by photo, the image is processed locally using Apple's Vision framework for OCR. Images are not uploaded anywhere.

**AI inference.**

- *On-device mode (default):* The Bonsai 8B model runs entirely on your iPhone using Apple's MLX framework. No prompts or responses leave the device. The model weights are downloaded once from HuggingFace's public model repository on first use.
- *BigBro mode (optional):* If you choose to pair LittleChef with a Mac running the BigBro companion app on your local network, prompts and responses — and, if you turn on BigBro voice, recorded audio and synthesized speech — are sent over your local Wi-Fi network to that Mac for processing. They do not leave your local network.

**Recipe URL imports.** When you import a recipe from a URL, the app fetches the page directly from that website using the standard iOS web view. The destination website may log the request as it would any normal browser visit, subject to that site's own privacy policy.

## Data we do not collect

- No account or sign-up is required, and we do not collect names, emails, phone numbers, or device identifiers.
- No analytics, telemetry, crash reporting, or usage tracking.
- No advertising or third-party SDKs.
- No location data.

## Permissions

- **Microphone** — required for voice questions while cooking.
- **Speech Recognition** — required to convert your voice to text on-device.
- **Local Network** — used only to discover an optional Mac running BigBro on your home network. No connections are made without your pairing.
- **Notifications** — used only for timer completion alerts.
- **Photo Library** — used only for selecting a recipe photo to import. The photo is processed on-device.

You can revoke any of these permissions at any time in iOS Settings.

## Children

LittleChef is not directed at children under 13 and does not knowingly collect any information from anyone of any age.

## Data deletion

You can delete all locally stored data at any time from Settings → Delete All Data. Uninstalling the app also removes local data. iCloud-synced data can be removed from Settings → [your name] → iCloud → Manage Storage.

## Changes

If this policy ever changes, the updated version will be posted at this URL with a new "Last updated" date.

## Contact

Questions: the.cedster@gmail.com
