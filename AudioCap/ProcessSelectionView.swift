import SwiftUI

@MainActor
struct ProcessSelectionView: View {
    @State private var processController = AudioProcessController()
    @State private var tap: ProcessTap?
    @State private var recorder: ProcessTapRecorder?
    @State private var streamer = WebSocketStreamer()

    @State private var selectedProcess: AudioProcess?
    @State private var transcriptEnabled = true
    @State private var saveToFile = false
    @State private var subtitlePanel: FloatingSubtitlePanel?

    var body: some View {
        Section {
            Picker("Process", selection: $selectedProcess) {
                Text("Select…")
                    .tag(Optional<AudioProcess>.none)

                ForEach(processController.processGroups) { group in
                    Section {
                        ForEach(group.processes) { process in
                            HStack {
                                Image(nsImage: process.icon)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 16, height: 16)

                                Text(process.name)
                            }
                                .tag(Optional<AudioProcess>.some(process))
                        }
                    } header: {
                        Text(group.title)
                    }
                }
            }
            .disabled(recorder?.isRecording == true)
            .task { processController.activate() }
            .onChange(of: selectedProcess) { oldValue, newValue in
                guard newValue != oldValue else { return }

                if let newValue {
                    setupRecording(for: newValue)
                } else if oldValue == tap?.process {
                    teardownTap()
                }
            }
        } header: {
            Text("Source")
                .font(.headline)
        }

        Section {
            Toggle("Save Audio File", isOn: $saveToFile)
                .disabled(recorder?.isRecording == true)
            Toggle("Live Transcript", isOn: $transcriptEnabled)
                .disabled(recorder?.isRecording == true)
        } header: {
            Text("Options")
                .font(.headline)
        }

        if let tap {
            if let errorMessage = tap.errorMessage {
                Text(errorMessage)
                    .font(.headline)
                    .foregroundStyle(.red)
            } else if let recorder {
                RecordingView(recorder: recorder)
                    .onChange(of: recorder.isRecording) { wasRecording, isRecording in
                        /// Each recorder instance can only record a single file, so we create a new file/recorder when recording stops.
                        if wasRecording, !isRecording {
                            createRecorder()
                        }
                    }

                if transcriptEnabled {
                    TranscriptView(streamer: streamer)

                    if recorder.isRecording && streamer.isConnected {
                        Button {
                            if subtitlePanel == nil {
                                subtitlePanel = FloatingSubtitlePanel(streamer: streamer)
                            }
                            subtitlePanel?.show()
                        } label: {
                            Label("Floating Subtitle", systemImage: "text.bubble")
                        }
                    }
                }
            }
        }
    }

    private func setupRecording(for process: AudioProcess) {
        let newTap = ProcessTap(process: process)
        self.tap = newTap
        newTap.activate()

        createRecorder()
    }

    private func createRecorder() {
        guard let tap else { return }

        let audioFileURL: URL? = saveToFile ? {
            let filename = "\(tap.process.name)-\(Int(Date.now.timeIntervalSinceReferenceDate))"
            return URL.applicationSupport.appendingPathComponent(filename, conformingTo: .wav)
        }() : nil

        let newRecorder = ProcessTapRecorder(fileURL: audioFileURL, saveToFile: saveToFile, tap: tap)
        newRecorder.streamer = transcriptEnabled ? streamer : nil
        self.recorder = newRecorder
    }

    private func teardownTap() {
        tap = nil
    }
}

extension URL {
    static var applicationSupport: URL {
        do {
            let appSupport = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            let subdir = appSupport.appending(path: "AudioCap", directoryHint: .isDirectory)
            if !FileManager.default.fileExists(atPath: subdir.path) {
                try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
            }
            return subdir
        } catch {
            assertionFailure("Failed to get application support directory: \(error)")

            return FileManager.default.temporaryDirectory
        }
    }
}

