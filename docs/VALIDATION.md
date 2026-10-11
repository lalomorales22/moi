# Validation — 2026-10-10

## Completed locally

- Shared Swift package builds with Xcode 26.6 / Swift 6.3 in Swift 5 language mode.
- Ten Swift tests pass: fragmented UTF-8 requests, ambiguous HTTP framing, oversized requests, bearer authentication, chat validation, corrupt/truncated model rejection, and a real TCP listener's authentication, public browser resources and CSP, own-origin access, foreign-origin rejection, thermal gate, error recovery, privacy-safe activity log, and shutdown. Pairing tests cover expiry boundaries, replay rejection, session bounds, revocation, and station reset.
- Unsigned iOS arm64 Release app compiles and links against the actual LiteRT-LM iOS framework.
- Real Qwen 3 0.6B INT4 inference on the Mac passes authenticated API checks, invalid-request rejection, non-streamed chat, streamed chat with `[DONE]`, token accounting, and metrics.
- Real Gemma 4 E2B inference on the Mac passes the same API checks.
- Runtime logs identify Apple's M1 / Metal backend during the Mac runs.
- Qwen 3, Gemma 3, and Gemma 4 model files match their pinned upstream byte counts and SHA-256 checksums.
- Python examples compile; the installer passes Bash syntax checking.

The Mac is an M1 with 8 GB RAM. Its results are separate from the physical-device results below.

## Device preparation

The connected device reports iPhone 11, 64 GB storage, 4 GB physical RAM, and iOS 27.0.1. Computer trust, Developer Mode, and the app developer profile are enabled. Installing Xcode's iOS 26.5 platform and building against the connected phone's UDID resolved provisioning. The signed Release app installed and opened successfully. Verified model files were copied to its app container over USB.

## Physical iPhone results

Qwen 3 0.6B loaded with the Metal backend in the Debug build. Real API checks passed over both USB forwarding and direct local Wi-Fi: authentication, model listing, invalid request rejection, non-streaming inference, SSE completion, and token accounting. A second concurrent generation returned HTTP 429 while the first completed normally.

| Qwen check | Observed result |
|---|---|
| 12-token greeting over Wi-Fi | 48.9 decode tokens/sec; first content in 0.289 sec |
| 128-token response over Wi-Fi | 54.5 decode tokens/sec; first content in 0.365 sec; total 2.64 sec |
| Sampled app memory after greeting | 460 MiB |
| Sampled available app memory | 1,637 MiB |
| Sampled iOS thermal state | Fair, shown as Warm |

Times are measured inside the inference engine/app, not full client round-trip times. These are short synthetic smoke tests, not sustained benchmarks or answer-quality evaluations. App memory figures are snapshots, not peak allocations. The generated explanation contained inaccurate claims, illustrating the limits of a 0.6B model.

Gemma 4 E2B failed during loading. The last receipt sampled 2,092 MiB app memory with only 5 MiB available, and the device console reported termination by signal 9. Apple's JetsamEvent report at 19:14:44 confirms MOI was killed for `per-process-limit`. It never reached serving or generated a response. MOI now blocks this bundle on devices with less than 6 GB physical RAM; that threshold does not prove compatibility above it.

The memory guard was then verified on the physical phone: the same Gemma startup request produced an explanation without loading the model, the app stayed running, and sampled app memory was 16 MiB.

The final signed Release build was installed and launched through `./start.sh install`. Its binary was checked to exclude both Debug startup environment overrides. The USB test proxy was stopped; normal clients connect directly over Wi-Fi using the phone's own Keychain API key. The eight shared-core tests still pass after the guard change.

The user confirmed the normal Release build shows LIVE after loading Qwen and starting the station. A direct Wi-Fi check reached that build and confirmed that missing credentials and the retired Debug key both receive HTTP 401.

Gemma 3 270M was subsequently downloaded without authentication from the pinned public 72fstudio mirror. Its 304,005,120 bytes and SHA-256 match the original LiteRT community artifact. The native phone downloader, checksum verification, and CPU loading path all completed successfully through a Debug startup invocation. Gemma 3 passed direct Wi-Fi API authentication, validation, non-streaming chat, SSE completion, and token accounting. Its 11-token greeting measured 34.2 decode tokens/sec, first content in 0.189 sec, and 0.450 sec total generation time. Sampled footprint was 398 MiB after loading and 411 MiB after inference, with nominal thermal state. These remain short smoke results, not sustained benchmarks.

The device receipt confirms the visible model choices on this 4 GB phone are `qwen3-0.6b` and `gemma-3-270m`. Gemma 4 is hidden as well as blocked. The app's access-token input was removed because all current catalog downloads are public. Model licenses still apply. The updated Release build was installed and launched, with all three Debug startup override strings verified absent from its binary.

## Still to verify

Foreground/background transitions, thermal behavior over longer runs, Wi-Fi changes, and manual interaction with the download progress/cancel UI. The underlying phone download path has been exercised successfully for Gemma 3. Gemma 4 needs a different artifact or a phone with more memory.

## QR link sharing

Connect renders a local QR code and offers the system Share link action. Apple's Vision barcode decoder recovered the exact original URL from two rendered codes, including a different host and port. The user confirmed visibility and scanning from a separate phone. That scan exposed a usability issue: the original `/v1` link returned an authentication error in a browser.

The QR now opens a browser page at `/`; old `/v1` links also serve that page. Static resources are public with proper MIME types, no-store, and a restrictive content security policy. API routes still require a bearer key. Unit checks cover missing credentials, the permitted local origin, mismatched Host, foreign origin, and wrong port.

Desktop Safari reached the actual iPhone over Wi-Fi with the updated Debug build. Manual browser checks passed: dummy key reveal/hide, friendly wrong-key error, successful authentication, a real Gemma 3 prompt, and disconnect clearing the key and disabling submission. The 24-token robot-name response appeared in 0.9 seconds measured by the browser. Desktop Chrome also verified authentication on the initial browser implementation. These are desktop browser checks against a physical iPhone server, not a mobile Safari interaction test.

The native Connect tab now includes Reveal API key and hides it on tab changes, key changes, and leaving the app. The browser includes Show what I’m typing for manual entry from another phone. API keys remain excluded from the QR and shared URL. Native reveal interaction, mobile layout, and the system share sheet still need hands-on verification. The signed Release build with these changes was installed and launched successfully. All four bundled web assets match the tested source, and all three Debug startup override strings are absent from the Release binary. All eight Swift tests and JavaScript syntax checks pass.

## Automatic QR pairing

The manual-entry flow was replaced with single-use QR pairing. Ten Swift tests and four JavaScript client tests pass. The listener tests use a full 68-character native-format API key and confirm authentication succeeds; the reported exact-key failure was not reproduced. Manual entry now normalizes whitespace and hexadecimal capitalization and reports incomplete keys clearly. This is a usability improvement, not a confirmed diagnosis of the user's failed attempts.

The pairing tests verify that the main key is never returned, invitations cannot authenticate inference directly, reused/expired invitations fail, foreign or absent browser origins cannot redeem them, sessions expire and are capped at 16, and disconnect/reset revokes access. Client tests cover fragment removal before exchange, storing only browser credentials, refresh recovery, expired-code errors, manual-key normalization, and disconnect.

Desktop Safari opened a real invitation generated by the physical iPhone's Debug build. It showed **Paired automatically** without typing a key, completed an actual Gemma 3 request (4 output tokens, 0.6 seconds browser elapsed time), and reconnected after page refresh. Reusing the consumed invitation against the iPhone returned 401. Browser Disconnect reduced the phone's paired-session count from one to zero. The real app QR renderer and Apple's Vision decoder round-tripped a full-length pairing URL including its fragment.

Physical testing obtained the short-lived invitation through an explicitly enabled Debug-only app-container export, separate from the secret-free status receipt; no main key was exported. The signed Release build was installed and launched successfully. Its bundled browser assets match the tested source, and all four Debug override strings plus the invitation-export path are absent from the binary. The user then confirmed that scanning the fresh QR from a separate physical phone opened the page and showed “Paired automatically” without asking for the API key. This verifies the camera-to-browser pairing flow on the installed Release app; inference from that second phone has not yet been reported. HTTP remains unencrypted on trusted local Wi-Fi.

## Conversational browser UI

The browser now has a mobile chat transcript, bottom composer, streamed replies, Stop, and New chat. Twelve JavaScript behavior tests pass alongside the ten Swift tests. Client checks cover immediate composer clearing, preserving a draft while a reply arrives, incremental UTF-8/SSE decoding, rendering model text safely, sending prior exchanges, trimming complete pairs to the byte/message limits while preserving the visible transcript, resetting chat without disconnecting, cancellation, failed and truncated replies, late output after New chat, and oversized multibyte input. Existing pairing/refresh/manual-key/disconnect checks still pass.

Chrome's device toolbar at 390 × 844 displayed the actual iPhone-served page with the compact header, message bubbles, and bottom composer. Sending a message cleared the composer. An initial live reply was interrupted when the Debug phone process terminated; the client preserved its partial text and reported the interruption. After relaunching the phone app, real Wi-Fi SSE requests completed with `[DONE]`, and a two-turn cat-name check included Mango in the follow-up answer. No transport change was needed to obtain complete streams.

The shipping JavaScript was also run in a DOM test harness using real fetch calls to the physical iPhone's Qwen 3 engine. It successfully consumed three complete streams: an initial message, a follow-up containing prior conversation, and a fresh chat that reached the 256-token reply limit. The composer cleared immediately and retained a new draft during each reply. The first two browser-client elapsed times were about 1.8 and 1.6 seconds; these are brief functionality checks, not model-quality or sustained performance benchmarks.

The signed Release build was installed and launched successfully. All four bundled web assets match the tested source. All four Debug startup override strings and the pairing-export path are absent from its binary. The mobile layout check used desktop Chrome emulation; physical mobile Safari keyboard behavior and hands-on use of the new chat remain to be verified. The previously confirmed physical QR pairing flow is preserved.

## Reproduce

Run `swift test`, `node --test Tests/WebClientTests.cjs`, `./start.sh build`, and `scripts/smoke-api.py` against the intended host. Models must be downloaded separately; test keys and build logs are excluded from Git. Debug-only startup overrides and a secret-free device receipt support physical testing, but the shipping Release app excludes those overrides.
