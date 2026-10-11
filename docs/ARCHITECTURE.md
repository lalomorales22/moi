# MOI — mom's old iPhone

Turn a spare iPhone into a small, local inference appliance. The phone downloads and runs the model; LAN clients send requests directly to it. No cloud inference account or Mac proxy is required after installation.

## First implementation

- SwiftUI dashboard and model setup, iOS 17+.
- Google's LiteRT-LM 0.18.0, pinned with verified binary checksums through Swift Package Manager.
- Qwen 3 0.6B INT4 and Gemma 3 270M, both publicly downloadable without credentials. Gemma 3 uses a pinned mirror with the original conversion's SHA-256. Gemma 4 E2B GPU is hidden on devices below the 6 GB RAM trial floor. Only text inputs in v0.1.
- Network.framework HTTP/1.1 listener with a bearer key, bounded requests and connections, one generation at a time, Bonjour discovery, and cancellation.
- `/health`, `/v1/models`, `/v1/chat/completions`, `/moi/stats`. OpenAI-compatible text chat subset, including SSE streaming. Unsupported features return explicit errors.
- Shared core also runs on macOS for real engine/API testing. A Mac result is not an iPhone performance result.
- Public mobile-first chat at `/` (also `/v1` for older QR links), with a scrollable transcript, keyboard-aware bottom composer, streamed replies, Stop, and New chat. Each request includes the latest complete user/assistant pairs, capped at six prior exchanges and 2,048 UTF-8 bytes including the new message. Older transcript entries remain visible. Aborted replies retain any text already received; failed requests without a reply do not create unmatched context turns. Session/chat identities prevent late responses from changing a replacement chat. No remote assets. Main keys and chat history stay in page memory; temporary paired-browser credentials use per-tab session storage; model output renders as text. API requests with an Origin header must match both an explicit local-origin allowlist and the Host header. No cross-origin API access.
- Pairing uses a 256-bit random invitation in the QR URL fragment, valid once for 120 seconds. A same-origin POST atomically consumes it and returns an independent 256-bit browser credential. Sessions expire after eight hours, are bounded to 16, and are revoked on station stop or explicit disconnect. Credentials and invitations never enter request targets or activity logs. This reduces key exposure but does not encrypt HTTP.
- Keychain for the API key; model files live in app Documents/Models. Prompts and completions are not persisted by MOI.

## Operating limits

The app must remain in the foreground. Serving disables automatic screen lock. Backgrounding stops the listener and cancels work. iOS controls suspension, memory limits, and thermal throttling; this is not an unattended background daemon. Use trusted local Wi-Fi: HTTP is unencrypted. Internet exposure and port forwarding are outside v0.1.

Keep the context at 1,024 tokens initially. Process one generation at a time. Reject new inference while the phone reports serious or critical thermal pressure. Memory pressure stops serving and releases the engine once active work has drained.

The install script can build, sign, push, and launch. Apple still requires an account in Xcode, device trust, Developer Mode, and a valid provisioning profile. Free personal signing needs periodic renewal. There is no supported way for a script to silently bypass those steps.

## Model evidence (2026-10-10)

Google's [Gemma guide](https://ai.google.dev/gemma/docs/core) distinguishes effective parameter count from total weights. It lists a small text-only mobile memory estimate, but that is not the on-disk size of every published artifact or a guarantee for iPhone 11.

The pinned [Gemma 4 E2B artifact](https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm) is 2,008,432,640 bytes for the GPU bundle. Runtime allocations, caches, and compilation add to that. It failed on the physical iPhone 11 while loading: a sampled 2,092 MiB footprint and 5 MiB available preceded signal 9 termination. MOI now blocks that bundle below 6 GB physical RAM. This is a conservative trial policy; larger phones have not yet been tested. Qwen 3 0.6B passed physical iPhone 11 loading and Wi-Fi API checks.

Official [Swift integration](https://developers.google.com/edge/litert-lm/swift) is early preview. Pin the runtime and model revisions so upgrades can be tested deliberately.

## Later

TLS or a separately configured private tunnel; additional proven model choices; sustained thermal benchmarks; fleet view. Public GitHub publication follows user review.
