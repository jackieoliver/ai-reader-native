# AI Reader

AI Reader is a native macOS menu-bar app shell for copied-text-to-speech.

Default local shortcuts:

- Double Control: read copied text.
- Summarize: summarize copied text and show it in the reusable summary chat window.
- Control Option: summarize copied text, show it in the reusable summary chat window, then read the summary.
- Control A: rewind 10 seconds while AI Reader is speaking.
- Control S: pause/resume while AI Reader is speaking.
- Control D: fast-forward 10 seconds while AI Reader is speaking.
- Control B: stop the current audio and cancel the active TTS stream.

The live flow uses the clipboard. Select text, copy it, then trigger AI Reader:

- Double Control reads the current clipboard text, splits it into phrase-sized segments, streams those segments to the selected Cartesia Sonic model over warm WebSocket continuations at fixed 1.5x speed, and starts playback as audio chunks arrive.
- Summarize reads the current clipboard text, streams it to Claude with `summary.md` as the system prompt, then shows summary text as it arrives in a reusable chat window.
- Control Option reads the current clipboard text, streams it to Claude with `summary.md` as the system prompt, shows summary text as it arrives in the same reusable chat window, then feeds summary chunks into the selected Cartesia Sonic model with WebSocket continuations.

AI Reader requests Accessibility only for the keyboard event tap used by shortcuts. Clipboard text capture does not use Accessibility.

## Cartesia Flow

```mermaid
flowchart TD
  A["User selects and copies text"] --> B{"Shortcut"}
  B -->|"Double Control"| C["Read clipboard text"]
  B -->|"Summarize"| D["Read clipboard text"]
  B -->|"Control Option"| D
  C --> E1["Direct text chunks<br/>Cartesia WebSocket continuations"]
  E1 --> E["Cartesia /tts/websocket<br/>model: sonic-3.5 or sonic-3<br/>voice: selected voice ID<br/>speed 1.5 + volume: generation_config"]
  D --> F["Claude Messages API<br/>system prompt: summary.md"]
  F --> G["Claude streaming summary"]
  G --> S["Singleton summary chat window<br/>summary streams as first Claude message"]
  S --> T["Follow-up questions to Claude<br/>summary stays as chat context"]
  G --> E2["Cartesia WebSocket continuations<br/>same context_id"]
  E2 --> E
  E --> H["Raw PCM audio chunks"]
  H --> I["AVAudioEngine streaming output"]

  J["API Keys window"] --> K["Cartesia API key in .env"]
  K --> L["Auto-load Cartesia /voices + warm WebSocket"]
  N["Preferences > Playback"] --> L
  L --> M["CARTESIA_VOICE_ID in .env"]
  N --> O["Volume in UserDefaults"]
  P["Summary menu"] --> Q["Claude model + live prompt type"]
  Q --> F
  K --> E
  M --> E
  O --> E
```

## Local Setup

```sh
cp .env.example .env
./script/build_and_run.sh
```

The default local build installs a stable development app at `/Applications/AI Reader Dev.app`
so macOS privacy grants survive rebuilds. For clean-room TCC tests, run
`AI_READER_APP_IDENTITY=permission-test ./script/build_and_run.sh`.

Provider API keys pasted in the app are stored in `.env` for this local development build. Cartesia voices load automatically after the key is saved, `CARTESIA_VOICE_ID` is selected automatically when needed, and model, volume, and voice can be changed from the menu. Speech sends Cartesia a fixed 1.5x speed request. Summary instructions live in editable files under `prompts/`, with Boil Down selected by default. The selected prompt file is read fresh from disk for each Claude generation, so prompt edits apply on the next summary without restarting AI Reader. The Claude summary model can be changed from the menu.

The menu and summary window show the latest timing report across capture, window display, Claude response headers, first streamed text, Claude completion, Cartesia continuation send, first audio chunk, and first audio scheduled locally. The aggressive TTS target is 50 ms from trigger to first audio scheduled locally; real end-to-end results still depend on network, Claude first-token time, and Cartesia first-chunk time.
