# Shipping MOI to TestFlight and the App Store

This is the path from a clean checkout to an internal TestFlight build, then App Review. It needs a Mac with full Xcode (with the iOS platform installed under Xcode → Settings → Components) and a paid Apple Developer Program membership.

`./start.sh` for USB installs keeps working the same way. It still passes its own team and bundle ID to `xcodebuild`, so existing `com.moi.phone` installs update in place. The steps below only matter for archives you start from Xcode.

## 1. Register the app

1. In [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list), register an explicit App ID in your paid team, e.g. `com.yourname.moi`. No extra capabilities are needed.
2. In [App Store Connect](https://appstoreconnect.apple.com) → Apps → **+** → New App, choose iOS, pick that bundle ID, and set a name and SKU. The name "MOI" may already be taken on the store. If so, use something like "MOI – Local AI Server" and keep `CFBundleDisplayName` as MOI.

## 2. Point the project at your team and bundle ID

```bash
cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig
# edit: DEVELOPMENT_TEAM = <your 10-char team ID>, PRODUCT_BUNDLE_IDENTIFIER = com.yourname.moi
```

`Config/Signing.local.xcconfig` is git-ignored. `Config/MOI.xcconfig` includes it when it exists and falls back to `com.moi.phone` with no team when it doesn't. Don't change the bundle ID in Xcode's Signing tab, because the next `xcodegen generate` overwrites it.

Using the same ID for archives and for `./start.sh` (`MOI_BUNDLE_ID=com.yourname.moi ./start.sh`) is fine. Keep in mind that a different ID is a separate app with separate data on the phone.

## 3. Generate the project

Either run `./start.sh build`, which downloads the pinned XcodeGen if needed and makes an unsigned Release build as a smoke test, or run `xcodegen generate` yourself. Then open `MOI.xcodeproj`.

## 4. Set version and build number

`MARKETING_VERSION` (e.g. `0.1.0`) and `CURRENT_PROJECT_VERSION` live in `project.yml`. Every upload needs a build number higher than the last one for that version. Either bump `CURRENT_PROJECT_VERSION` in `project.yml`, or set `CURRENT_PROJECT_VERSION = N` in `Config/Signing.local.xcconfig`. Regenerate the project after either change.

## 5. Archive and upload

1. Choose the **MOI** scheme and **Any iOS Device (arm64)** as the destination.
2. **Product → Archive.** The scheme archives Release.
3. In the Organizer: **Distribute App → App Store Connect → Distribute**. Automatic signing creates the distribution certificate and profile.
4. Export compliance is already answered: `ITSAppUsesNonExemptEncryption` is `NO`. MOI uses only HTTPS through URLSession, Keychain storage, `SecRandomCopyBytes`, and SHA-256 integrity checks, which are all exempt.

The app ships an iPhone-only (`TARGETED_DEVICE_FAMILY = 1`) single-size 1024×1024 `AppIcon` asset catalog and a `PrivacyInfo.xcprivacy`. If the upload fails because of the icon, check that the PNG is still opaque. `scripts/make-icon.swift` regenerates it without alpha.

## 6. Internal TestFlight

Processing takes about 5–30 minutes. Then go to App Store Connect → your app → TestFlight → Internal Testing, create a group, add yourself (testers must be App Store Connect users on your team), and install through the TestFlight app on your iPhone. Internal builds skip beta review and expire after 90 days. External testers need a quick Beta App Review first.

A TestFlight or App Store build starts with no model. Get one with Model → Download model on the phone. `./start.sh push-model` and the USB setup flow need a development-signed build, because distribution-signed apps don't let `devicectl` write into their container.

## 7. App Store submission

Before you click **Add for Review**, you need:

- **Screenshots:** the iPhone 6.9" set (1320×2868 or 1290×2796 portrait, from an iPhone 16/17 Pro Max simulator or device), 1–10 images. App Store Connect scales them down for smaller iPhones. No iPad screenshots are needed because the app is iPhone-only.
- **Privacy policy URL:** required for every app, even one that collects nothing. A short page (GitHub Pages or a `PRIVACY.md` rendered on GitHub works) should say that prompts, responses, and keys stay on the phone and the local network, and that the only outbound request is the model download from Hugging Face.
- **App Privacy:** answer **Data Not Collected**. This matches `PrivacyInfo.xcprivacy`: no tracking, no collected data types. Required-reason APIs declared: UserDefaults `CA92.1` (selected model ID) and disk space `85F4.1` + `E174.1` (free space is shown on the Model screen and checked before a download).
- **Age rating:** the questionnaire asks about generated or unrestricted content. A general-purpose LLM can produce unfiltered text, so answer honestly.
- **Support URL:** the GitHub repo is fine.

### Suggested App Review notes

> MOI turns an iPhone into a small private AI server for the user's own local network. Everything runs on-device; there is no account, login, or backend service.
>
> • Local network: MOI runs an HTTP server on the phone (port 8080) and advertises it over Bonjour (`_moi._tcp`) so the user's other devices on the same Wi-Fi can use it from a browser or an OpenAI-compatible API client. iOS shows the Local Network permission prompt when serving starts; please tap Allow. Requests require an API key held in the phone's Keychain, or a single-use QR pairing.
>
> • Model download: language models are downloaded inside the app from public Hugging Face URLs pinned to exact revisions. They are data files (weights) run by the bundled LiteRT-LM runtime, not executable code, and each file is verified by SHA-256 before it is loaded.
>
> To test:
> 1. Join Wi-Fi. Open the **Model** tab, choose **Gemma 3 · 270M** (about 304 MB) or **Qwen 3 · 0.6B** (about 345 MB), and tap **Download model**, then **Load model**.
> 2. Open **Station** and tap **Start serving**. Allow Local Network access.
> 3. Open **Connect** and scan the QR code with a second device on the same Wi-Fi. It opens the chat page and pairs automatically. Without a second device, tap **Copy website link**, open it in Safari on the same iPhone, and enter the API key from **Reveal API key** to chat.
> 4. The **Activity** tab shows the served requests.

The review device needs Wi-Fi for the download and the LAN address. Keep the notes short and put the steps first.
