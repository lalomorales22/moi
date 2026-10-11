# MOI

**mom’s old iPhone. now a little inference server.**

MOI is a native iPhone app that runs a small language model on the phone and serves a local HTTP API. Give a spare phone power and Wi-Fi, open MOI, and let your other projects call it.

The dashboard shows app memory, available memory, battery, thermal pressure, connected clients, completed requests, and measured generation speed. Prompts and responses are not saved by MOI. No cloud inference service is used.

This is an early prototype. Qwen 3 0.6B and Gemma 3 270M run on a physical iPhone 11 and pass real Wi-Fi chat and streaming API checks. See [validation](docs/VALIDATION.md) for measurements and remaining limits.

## Install from a Mac

You need Xcode with the iOS SDK, an Apple account added in Xcode → Settings → Accounts, and a connected iPhone running iOS 17 or newer. The script installs XcodeGen through Homebrew if needed. Models and build dependencies download separately and are not stored in Git.

1. Unlock the phone, connect it by cable, and tap **Trust**.
2. Enable **Settings → Privacy & Security → Developer Mode**, restart, and confirm after unlocking. If the setting is missing, open Xcode → Window → Devices and Simulators. If libimobiledevice is already installed, `idevicedevmodectl reveal` can reveal the menu; it does not enable the setting for you.
3. Run from this repository:

```sh
./start.sh
```

The script detects a signing team from an existing Apple Development certificate, builds, signs, installs, and launches MOI. If automatic detection does not select your intended team:

```sh
MOI_TEAM_ID=YOUR_TEAM_ID ./start.sh install
```

If the phone says **Untrusted Developer**, go to Settings → General → VPN & Device Management → Developer App, trust your own signing profile, and reopen MOI. If Xcode says its iOS platform is not installed, install that platform in Xcode Settings → Components before trying again.

If more than one phone is connected, set `MOI_DEVICE_ID` to the device identifier printed by `./start.sh doctor`. If Apple says the bundle ID is unavailable, use `MOI_BUNDLE_ID=com.yourname.moi` for both install and push-model commands.

Apple controls device trust, Developer Mode, signing, and provisioning. A free Personal Team typically requires reinstalling a development build after seven days. The script does not bypass those requirements or change your phone’s data.

## On the phone

1. Open **Model**, choose **Qwen 3 · 0.6B**, and tap **Download model**.
2. Tap **Load model**. Return to **Station** and tap **Start serving**.
3. Allow **Local Network** access if iOS asks.
4. Under **Connect**, scan the QR code, tap **Share link**, or copy the base URL into your client. Copy the API key separately.

The QR code is generated on the phone and contains only its current API base URL. It updates when the Wi-Fi address or port changes. Other devices need the same local network and an API client configured with MOI's key; the link is an API endpoint, not a browser chat page.

Keep MOI in the foreground. Serving keeps the screen awake. Locking the phone or leaving the app stops serving; reopen it and tap Start serving again. Use a trusted local network: this prototype serves plain HTTP, so it does not encrypt API traffic. Do not expose it through router port forwarding.

### Models

| Model | Download | Backend | Purpose |
|---|---:|---|---|
| Qwen 3 0.6B INT4 | 345 MB | Metal | Tested on iPhone 11; no Hugging Face account required |
| Gemma 3 270M Q8 | 304 MB | CPU, 2 threads | Public mirror; no account or token required |
| Gemma 4 E2B | 2.01 GB | Metal | Hidden on iPhone 11; experimental option only on phones with 6+ GB RAM |

File size is not working memory. A model advertised as “E2B” can contain more stored parameters than its effective parameter count. The 64 GB storage capacity is not the phone’s RAM.

The tested Gemma 4 bundle was terminated during loading on iPhone 11 near its 2.1 GB app memory limit. MOI hides it from the model picker and blocks downloading/loading it on phones below 6 GB physical RAM. The 6 GB floor is a conservative trial policy, not a claim of compatibility; phones above that floor remain untested. A smaller Gemma 4 conversion may be worth investigating later.

Gemma 3 downloads from the public [72fstudio mirror](https://huggingface.co/72fstudio/gemma-3-270m-it). Its pinned artifact has the same size and SHA-256 as the [original LiteRT conversion](https://huggingface.co/litert-community/gemma-3-270m-it). MOI verifies those bytes before loading. No Hugging Face login or token is required, and the original Gemma terms still apply. The app links both the original model card and its download source.

Models use pinned revisions and SHA-256 checksums. MOI verifies downloads before accepting them and verifies again when loading. Model cards and applicable terms are linked inside the app. Models retain their own licenses; they are not relicensed by MOI.

For USB transfer instead of downloading on the phone, install and open MOI once, then run:

```sh
./start.sh push-model qwen3-0.6b
./start.sh push-model gemma-3-270m
```

For a suitable newer phone, `./start.sh push-model gemma-4-e2b` copies the larger experimental bundle. The phone still applies its memory compatibility check before loading it.

The files go into the app’s `Documents/Models` folder. They can also be transferred through Finder file sharing. All catalog downloads are public and require no access token.

## API

Every route requires `Authorization: Bearer YOUR_MOI_KEY`.

| Method | Route | Result |
|---|---|---|
| GET | `/health` | Readiness and active model |
| GET | `/v1/models` | Loaded model in OpenAI-compatible list format |
| POST | `/v1/chat/completions` | Text response or SSE stream |
| GET | `/moi/stats` | Request counts, connections, timing, and last engine throughput |

Configure an OpenAI-compatible SDK with the phone’s `http://PHONE_IP:8080/v1` base URL and the MOI key. This does not use an OpenAI account or an OpenAI API key. Bonjour discovery advertises `_moi._tcp`.

Use the included client:

```sh
export MOI_BASE_URL='http://PHONE_IP:8080'
read -s MOI_API_KEY
export MOI_API_KEY
python3 examples/client.py 'write a two-sentence greeting'
python3 examples/client.py --stream 'give me three names for a small robot'
```

The key input is hidden; paste the key and press Return. `MOI_BASE_URL` here does not include `/v1`; the example adds the route.

Supported chat fields: `model`, `messages`, `stream`, `max_tokens`, `temperature`. `model: "moi"` aliases the loaded model. History supports an optional initial system message followed by alternating text user/assistant messages, ending in a user message. Each HTTP request gets a fresh inference conversation; pass previous turns explicitly.

Limits: 1,024-token context, 2,048 UTF-8 bytes of message text, 1–256 output tokens (128 default), 32 messages, 16 KB request body, 8 simultaneous sockets, one active generation, and a 180-second request deadline. The runtime can reject a prompt whose actual tokenization exceeds its context. Overlapping inference requests receive `429` with `Retry-After: 5`. Serious/critical thermal pressure returns `503` for new inference. Backgrounding, memory warnings, and server shutdown cancel work.

Tools, images, audio, embeddings, JSON response schemas, browser-origin requests, and other OpenAI fields are not supported in v0.1. Unsupported fields receive an explicit `400`. Streaming failures after headers are sent appear as an SSE error object and a closed connection. Token usage is included only when the runtime provides it; throughput is not estimated from word counts.

## Development

```sh
./start.sh doctor
./start.sh build
swift test
```

`project.yml` generates the Xcode project. The Swift package contains the shared parser, authentication, HTTP server, model catalog, and LiteRT-LM engine. `App/` contains the actual SwiftUI app.

You can run the same core on a Mac for API development:

```sh
python3 scripts/download-model.py qwen3-0.6b
# Set MOI_API_KEY to a random key of at least 24 characters first.
swift run moi-host qwen3-0.6b models/Qwen3-0.6B_dynamic_wi4b32_afp32.litertlm 8081
```

In another terminal with the same key set:

```sh
python3 scripts/smoke-api.py http://127.0.0.1:8081
```

Mac benchmarks do not establish phone performance. Debug builds also support `MOI_TEST_MODEL` and `MOI_TEST_API_KEY` launch environment variables for physical-device testing, plus `MOI_TEST_DOWNLOAD=1` to exercise the phone downloader when the model is absent. Those builds write a secret-free `Documents/MOI-test-status.json` receipt. These overrides are excluded from Release builds.

See [architecture and limitations](docs/ARCHITECTURE.md). Public GitHub publication is intentionally a later step.
