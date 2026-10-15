# Validation — 2026-10-15

Built on Apple Silicon, macOS 26.7.1, Xcode 27.0, Swift 6.4. Deployment target: macOS 14. No third-party package dependencies.

## Passed

- Production build and strict code-signature verification. Delivered executable SHA-256: `e50b2891c7d8786225c7e63a8dc082455eb4b05d7729797038563316059c8036`.
- Eleven automated tests, including real RSA signature verification/tampering, PKCE, callback state/account mismatch/duplicate rejection, stream framing and terminal failures, Unicode citations, request history with image data, owner-only local persistence, and interrupted response recovery.
- Native AppKit regression: an isolated image-only PNG pasteboard enables Paste in the plain-text composer and invokes the image attachment callback. Empty/unsupported content produces a visible error. The test never reads or replaces the user's general clipboard.
- Personal ChatGPT Pro sign-in completed by Felipe in the system browser. The native app received the account's model catalog and selected GPT-6.1-Sol.
- A real streamed rewrite completed and was saved locally.
- A real hosted web search displayed “Searching the web…” and completed with a clickable Apple documentation link. The source link remained in the saved message.
- History sidebar and new-chat keyboard commands exercised in the native app. Sign-in and both live chats survived restarting into a release build.
- After Felipe approved Keychain access, Command–V attached his macOS clipboard screenshot with a 928 × 445 preview. Felipe confirmed paste and submission, and the completed model answer correctly read the text in the image.
- An earlier release's idle physical footprint was sampled at 31.5 MB. This is a single observation, not a memory ceiling or a performance benchmark. The final executable is about 1.9 MB.

## Screenshot fix and remaining checks

Felipe reported that pasting a macOS screenshot did nothing. Native menu inspection confirmed Paste was disabled for an image-only clipboard because AppKit treated the composer as a plain-text editor. The fix overrides command validation and handles PNG/TIFF data explicitly. Copied image files are also accepted. The regression tests and the live screenshot preview, submission, and model-answer check now pass.

Keychain access was approved and sign-in remained intact. macOS can request access again when an ad-hoc signed executable changes. The native screenshot check used the release process containing the paste fix, launched before the final testability-only change that injects an isolated pasteboard into regression tests. The delivered bundle defaults to the same system clipboard and includes that change; its signature and executable checksum were verified separately.

The automated runner initially lacked pasteboard-service access in its shell sandbox. The already-built test bundle was run directly with `xcrun xctest .build/out/Products/Debug/QuickChatCoreTests.xctest` outside that sandbox, using its isolated pasteboard: **11 tests, 0 failures**. A separate Swift SDK stat-cache helper stalled outside the sandbox and was stopped; rebuilding inside the sandbox succeeded.

## Not yet established

- Global shortcut behavior across fullscreen Spaces and multiple monitors, shortcut-to-focused-input p95, and extended resource usage.
- Live token expiry/renewal, remote revocation, account switching, and real usage-limit responses. The relevant handling is implemented but not yet exercised end to end.
- Copied image files in Finder and image input across every available model. Live screenshot inference was verified with GPT-6.1-Sol.
- Public distribution, notarization, auto-updates, Intel Mac testing, or launch-at-login behavior.

No repository was published and no remote PR was created. Test chats remain local so Felipe can review the live results.
