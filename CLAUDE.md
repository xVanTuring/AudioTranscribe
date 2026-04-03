# AudioCap

macOS native app that captures audio output from any running process. Built with SwiftUI, requires macOS 14.4+.

## Architecture

Uses CoreAudio process tap API (not ScreenCaptureKit):
```
Process audio → AudioHardwareCreateProcessTap → Aggregate Device → I/O callback → file write + WebSocket stream
```

## Project Structure

```
AudioCap/
├── AudioCapApp.swift              # @main entry point
├── RootView.swift                 # Permission handling (TCC SPI)
├── ProcessSelectionView.swift     # Process picker, options toggles, session orchestration
├── RecordingView.swift            # Start/Stop button, file proxy display
├── FileProxyView.swift            # Draggable recorded file
├── RecordingIndicator.swift       # Animated recording icon
├── ProcessTap/
│   ├── ProcessTap.swift           # Core tap + aggregate device lifecycle; ProcessTapRecorder class
│   ├── AudioProcessController.swift # Process enumeration via NSWorkspace + CoreAudio
│   ├── AudioRecordingPermission.swift # TCC permission check/request
│   └── CoreAudioUtils.swift       # AudioObjectID property read helpers
└── Transcript/
    ├── WebSocketStreamer.swift     # WebSocket client to live-transcript server
    ├── AudioResampler.swift        # AVAudioConverter: source format → 16kHz mono int16
    └── TranscriptView.swift        # Real-time transcript display + latency badges
```

## Build

Open `AudioCap.xcodeproj` in Xcode 15.3+. Build and run.

```bash
xcodebuild -scheme AudioCap -configuration Debug build
```

## Key Design Decisions

- **ProcessTapRecorder** is the central class: owns the dispatch queue, I/O callback, file writing, and WebSocket streaming
- `saveToFile` controls whether audio is written to disk; `streamer` (optional) controls WebSocket streaming — both are set before `start()` and locked during recording
- Audio I/O callback runs on QoS `.userInitiated` dispatch queue; resampling + WebSocket send happen inline in the callback
- **AudioResampler** uses `AVAudioConverter` to downsample (typically 48kHz stereo float32 → 16kHz mono int16) for the ASR server
- WebSocket uses `URLSessionWebSocketTask`; receive loop is callback-based, send is fire-and-forget from the audio thread
- Latency metrics: `lastProcessingMs` (server ASR decode), `lastCorrectionMs` (2nd-pass), `lastRoundTripMs` (client-measured send→recv)

## Entitlements

- `com.apple.security.app-sandbox` — sandboxed
- `com.apple.security.device.audio-input` — audio capture
- `com.apple.security.files.user-selected.read-write` — file save
- `com.apple.security.network.client` — WebSocket to local server

## Audio Data Flow

1. User selects process → `ProcessTap.activate()` creates tap + aggregate device
2. `ProcessTapRecorder.start()` creates AVAudioFile (if `saveToFile`), sets up AudioResampler, connects WebSocketStreamer
3. I/O callback fires per audio buffer: writes to file + resamples + sends PCM over WebSocket
4. `ProcessTapRecorder.stop()` closes file, disconnects WebSocket, invalidates tap
