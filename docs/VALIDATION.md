# Validation — 2026-10-10

## Completed locally

- Shared Swift package builds with Xcode 26.6 / Swift 6.3 in Swift 5 language mode.
- Eight Swift tests pass: fragmented UTF-8 requests, ambiguous HTTP framing, oversized requests, bearer authentication, chat validation, corrupt/truncated model rejection, and a real TCP listener's authentication, thermal gate, error recovery, privacy-safe activity log, and shutdown.
- Unsigned iOS arm64 Release app compiles and links against the actual LiteRT-LM iOS framework.
- Real Qwen 3 0.6B INT4 inference on the Mac passes authenticated API checks, invalid-request rejection, non-streamed chat, streamed chat with `[DONE]`, token accounting, and metrics.
- Real Gemma 4 E2B inference on the Mac passes the same API checks.
- Runtime logs identify Apple's M1 / Metal backend during the Mac runs.
- Both model files match the pinned upstream byte counts and SHA-256 checksums.
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

## Still to verify

Foreground/background transitions, thermal behavior over longer runs, Wi-Fi changes, and the model download UI. Gemma 4 needs a different artifact or a phone with more memory. Gemma 3 270M remains untested because downloading it requires gated repository access.

## QR link sharing

Connect now renders a local QR code for the current API base URL and offers the system Share link action. Apple's Vision barcode decoder recovered the exact original URL from two rendered codes, including a different host and port. The updated Release app built, installed, and launched successfully; the user confirmed the QR is visible on the phone. A camera scan from a second physical device and sending through the share sheet have not been tested. API keys are excluded from the QR and shared URL.

## Reproduce

Run `swift test`, `./start.sh build`, and `scripts/smoke-api.py` against the intended host. Models must be downloaded separately; test keys and build logs are excluded from Git. Debug-only startup overrides and a secret-free device receipt support physical testing, but the shipping Release app excludes those overrides.
