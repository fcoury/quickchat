# Validation — 2026-10-15

Built on Apple Silicon, macOS 26.7.1, Xcode 27.0, Swift 6.4. Deployment target: macOS 14. No third-party package dependencies.

## Passed

- Production build and strict code-signature verification. Delivered executable SHA-256: `979ae01300f2035c5f99ed6755862fb43885311e55df97edc580a5697c3f8811`.
- Twelve automated tests, including real RSA signature verification/tampering, PKCE, callback state/account mismatch/duplicate rejection, stream framing and terminal failures, Unicode citations, request history with image data, owner-only local persistence, interrupted response recovery, and font shortcut modifiers/bounds/persistence.
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

## Window and settings update

The blank startup window was the empty SwiftUI Settings scene (`com_apple_SwiftUI_Settings_window`), separate from the AppKit chat panel. AppKit now owns the application lifecycle and its single panel; the placeholder scene was removed. Settings is a matching screen inside that panel, with account, window/shortcut, and local-data sections.

Native checks confirmed launch into the chat panel, opening Settings with both the gear and Command–Comma, returning with Escape, composer focus, preserved drafts and history, and cancelling shortcut recording without changing its displayed binding. The app-wide **Keep QuickChat on top** preference defaults off, updates the panel level immediately, and retained its enabled value through Command–N and a full restart. It was switched off again after testing. No additional inference request was needed for this UI update.

The final release was reopened and its complete settings layout inspected at 680 × 520. Command–N directly from Settings opened a new chat with the composer focused and retained the enabled on-top preference. The setting was then switched off. All 11 tests passed again after the changes. The native settings screenshot in the deliverables was captured from this release. Restart persistence and draft checks ran before the final layout/Command–N refinements; fullscreen and multiple-monitor behavior remain outside this check.

Repeated Keychain prompts during development were traced to ad-hoc signing: the current designated requirement identifies the executable by its code hash. No valid code-signing identity was available on this Mac when checked. Felipe approved the final build's Keychain prompt. A stable signing certificate is still needed to avoid changing this identity with each rebuild.

## Chat font-size update

Command–Plus (including Shift–Command–Plus) and Command–Equals increase chat text by one point; Command–Minus decreases it and Command–0 restores 15 points. The saved app-wide range is 12–26 points. Messages, code blocks, composer text, and its placeholder use the selected size. The shortcuts leave ordinary typing, Option/Control combinations, Settings, and shortcut recording alone.

The added regression test uses an isolated preferences suite and checks actual AppKit key events, shifted plus, Caps Lock/keypad modifiers, settings exclusion, clamping, reset, and persistence through state recreation. All 12 tests passed, and the release build succeeded.

Native checks exercised Command–Equals, Shift–Command–Plus, and Command–Minus in the focused composer. Transcript text and the placeholder resized visibly; the saved 18-point setting survived reopening the final release. Reset and bounds were verified by the regression test. Code-block resizing was compiled and reviewed but not separately exercised with a live code response.

Felipe also reported that the top-left corner of an assistant answer was cut off. The message container applied a rounded clipping mask to unpadded assistant text. Rounded corners now apply only to the background shape. The final release was visually checked with the reported “Bureaucracy.” answer: its first letter is intact, and the user bubble remains rounded.
