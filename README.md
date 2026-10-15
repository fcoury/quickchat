# QuickChat

A small native macOS menu-bar chat app for quick questions, rewrites, code discussion, and screenshots. Built with SwiftUI and AppKit, without third-party runtime dependencies or a Codex process.

## Build and run

Requires macOS 14 or later and Xcode / Swift 6 or later. The build targets the current Mac's architecture.

```sh
./scripts/build.sh
open dist/QuickChat.app
```

The bundle is ad-hoc signed for local use. It is not notarized for public distribution. You can copy it to Applications yourself. Rebuilding an ad-hoc signed app may cause macOS to ask for Keychain access again.

For development:

```sh
./scripts/build.sh debug
./scripts/swift.sh test
```

`scripts/swift.sh` keeps build caches inside `.build/`. The package has no plugins or downloaded dependencies; its manifest runs with SwiftPM's nested sandbox disabled to work inside an already sandboxed development session.

## Everyday use

- **Control–Option–Space** opens or hides QuickChat, keeping the window where you left it for the current session. Change the shortcut in Settings by clicking the recorder and pressing a combination containing Control, Option, or Command.
- **Return** sends. **Shift–Return** inserts a newline.
- **Escape** hides the panel and returns focus to the previous app. An active response continues; use Stop to cancel it.
- **Command–N** starts a fresh conversation, including from Settings, carrying your unsent text, screenshots, model, and search choice with you. The draft moves out of the previous chat; its sent messages stay in history. **Command–B** toggles searchable history. **Command–Comma** opens settings.
- **Command–Plus** (or **Command–Equals**) enlarges chat text, **Command–Minus** makes it smaller, and **Command–0** resets it. Messages, code, and the composer resize together. The size is saved across chats and restarts, from 12 to 26 points with a 15-point default.
- Settings opens inside the chat panel; **Escape** or the back arrow returns to your chat with its draft intact. Startup opens only the chat panel.
- **Keep QuickChat on top** in Settings defaults to off. It applies immediately and is saved for the app, across new chats, switching chats, and restarts.
- **Command–V** pastes text or screenshots into the composer. Preview or remove a screenshot before sending. Up to four images per message, 20 MB per image, and 50 megapixels per image.
- Choose an account-provided model in the top bar. Web search defaults to **Auto** and can be switched **Off** per chat. Search availability depends on the model/account. Responses retain clickable source links.
- Replies render Markdown headings, nested lists, quotes, tables, links, and inline code. Code blocks have syntax colors for common languages, horizontal scrolling, and a Copy button that preserves the source. A subtle **↔ Scroll** hint appears when code extends offscreen. Unknown languages and very large code blocks stay plain text. Short user messages use compact bubbles; prose caps at 720 points while code can use the full 960-point reply column.
- Right-click a chat to delete it, or right-click the menu-bar icon for settings and Quit.

## ChatGPT sign-in

Click **Continue with ChatGPT** and complete authorization in your system browser. QuickChat uses the documented public-client Sign in with ChatGPT flow for local personal/open-source apps. It does not reuse Codex credentials, need an API key, or call ChatGPT's private backend endpoints.

OAuth uses a loopback listener bound to `127.0.0.1`, a fresh state/nonce and PKCE challenge, and an issued per-account client ID. Identity tokens are checked against OpenAI's JWKS, issuer, audience, expiry, nonce, and returning account subject. Accounts, tokens, and the stable host ID are held in macOS Keychain. Refreshes are serialized and rotating tokens saved together. Sign-out attempts remote session revocation and clears local tokens while retaining the account registration.

Available models are discovered from the signed-in account. Each HTTP Responses request streams and uses `store: false`; it sends the conversation context and attached screenshots needed to continue that chat. A request counts as complete only after `response.completed`. Errors, partial responses, cancellation, and interrupted streams remain visible.

Eligible requests use your ChatGPT plan or credits, subject to availability and usage limits. **Manage usage** in Settings opens ChatGPT's usage controls. There is no alternate billing fallback.

Sources: [sign-in](https://developers.openai.com/siwc/token-sharing-open-source/sign-in), [models and inference](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference), [session management](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions), [preview limitations](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations), [web search](https://developers.openai.com/api/docs/guides/tools-web-search).

## Local data

Chats, unsent drafts, citations, and screenshots live in `~/Library/Application Support/QuickChat/`. Each chat is an atomic JSON file; images are separate PNGs. Directories use owner-only permissions, and data files use mode `0600`. This is local storage, not application-level encryption; normal macOS disk and account protections apply. Chat history is shared within this app across the saved accounts and is not synchronized with ChatGPT history.

Images are decoded into small thumbnails for display, while their original pixels are kept for model input. The window is retained between invocations and opening it never waits for a network request.

## Scope and validation

This first version supports text, pasted screenshots, local chat history, one response at a time, account/model selection, and hosted web search. It does not run shell commands or custom tools, read the selected text in other apps, synchronize history, or register itself to launch at login.

The test suite covers OAuth callback validation and PKCE, real RSA-signed identity verification and tampering, SSE framing and UTF-8, terminal stream failures, citation conversion, screenshot request replay, local persistence/recovery, and image-only native paste validation. Native paste tests require access to the macOS pasteboard service and use an isolated temporary pasteboard. `--demo` is an isolated UI preview with sample messages and simulated streaming; it does not use credentials or network calls and is not evidence of successful live inference.

See `VALIDATION.md` for the checks performed on the delivered build and any remaining limits.
