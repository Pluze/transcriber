import AppKit
import CryptoKit
import Darwin
import IOKit
import SwiftUI
import UniformTypeIdentifiers

struct ModelProfile: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let subtitle: String
    let filename: String
    let sha256: String
    let downloadURL: URL
    let downloadSize: String
    let fidelityRank: Int

    static let all: [ModelProfile] = {
        guard let url = Bundle.main.url(forResource: "models", withExtension: "json", subdirectory: "catalog"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode([ModelProfile].self, from: data),
              !catalog.isEmpty else {
            fatalError("The bundled model catalog is missing or invalid. Reinstall Transcriber.")
        }
        return catalog.sorted { $0.fidelityRank > $1.fidelityRank }
    }()
    static var maximum: ModelProfile { all.first { $0.id == "maximum" }! }
    static var balanced: ModelProfile { all.first { $0.id == "balanced" }! }
    static var compact: ModelProfile { all.first { $0.id == "compact" }! }
}

struct LanguageOption: Identifiable, Hashable, Codable {
    let code: String
    let name: String
    var id: String { code }

    static let all: [LanguageOption] = {
        guard let url = Bundle.main.url(forResource: "languages", withExtension: "json", subdirectory: "catalog"),
              let data = try? Data(contentsOf: url),
              let languages = try? JSONDecoder().decode([LanguageOption].self, from: data),
              !languages.isEmpty else {
            return [
                LanguageOption(code: "auto", name: "Auto — dominant language"),
                LanguageOption(code: "en", name: "English"),
                LanguageOption(code: "zh", name: "Chinese"),
            ]
        }
        return [LanguageOption(code: "auto", name: "Auto — dominant language")] + languages
    }()
}

extension Notification.Name {
    static let transcriberOpenFiles = Notification.Name("TranscriberOpenFiles")
}

struct HardwareProfile {
    let chip: String
    let memoryGiB: Int
    let logicalCores: Int
    let performanceCores: Int
    let threads: Int

    static func current() -> HardwareProfile {
        let bytes = ProcessInfo.processInfo.physicalMemory
        let memory = Int((Double(bytes) / 1_073_741_824.0).rounded())
        let cores = ProcessInfo.processInfo.processorCount
        let performanceCores = sysctlInt("hw.perflevel0.logicalcpu") ?? max(2, cores / 2)
        let chip = sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon"
        return HardwareProfile(
            chip: chip,
            memoryGiB: memory,
            logicalCores: cores,
            performanceCores: performanceCores,
            threads: max(2, min(8, performanceCores))
        )
    }

    var recommendation: String {
        if memoryGiB >= 16 && logicalCores >= 8 {
            return "Maximum Fidelity"
        }
        return "Maximum Fidelity (expect slower processing)"
    }

    var recommendedProfileID: String {
        if memoryGiB >= 16 && logicalCores >= 8 { return ModelProfile.maximum.id }
        if memoryGiB >= 10 { return ModelProfile.balanced.id }
        return ModelProfile.compact.id
    }

    var details: String {
        "Unquantized large-v3 · Metal · beam 5 · \(threads) performance-core threads · context reset"
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, value > 0 else { return nil }
        return Int(value)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return String(cString: value)
    }
}

struct ExecutionPlan: Sendable {
    let concurrency: Int
    let threadsPerFile: Int
    let reason: String
}

struct RuntimePolicy: Codable {
    let engine: String
    let policyVersion: Int
    let compatibleVersionContains: String
    let arguments: [String]
    let environment: [String: String]

    static let bundled: RuntimePolicy = {
        guard let url = Bundle.main.url(forResource: "runtime", withExtension: "json", subdirectory: "catalog"),
              let data = try? Data(contentsOf: url),
              let policy = try? JSONDecoder().decode(RuntimePolicy.self, from: data) else {
            fatalError("The bundled runtime policy is missing or invalid. Reinstall Transcriber.")
        }
        return policy
    }()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        NotificationCenter.default.post(name: .transcriberOpenFiles, object: urls)
    }
}

final class ModelDownloader: NSObject, URLSessionDownloadDelegate {
    var progressHandler: ((Double) -> Void)?
    var completionHandler: ((Result<URL, Error>) -> Void)?
    private var stableDownload: URL?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    func start(url: URL) {
        session.downloadTask(with: url).resume()
    }

    func cancel() {
        session.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progressHandler?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            let stable = FileManager.default.temporaryDirectory.appendingPathComponent("transcriber-model-\(UUID().uuidString).bin")
            try FileManager.default.copyItem(at: location, to: stable)
            stableDownload = stable
        } catch {
            completionHandler?(.failure(error))
            completionHandler = nil
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { session.finishTasksAndInvalidate() }
        if let error {
            completionHandler?(.failure(error))
        } else if let stableDownload {
            completionHandler?(.success(stableDownload))
        } else if completionHandler != nil {
            completionHandler?(.failure(NSError(domain: "Transcriber", code: 1, userInfo: [NSLocalizedDescriptionKey: "The model download did not produce a file."])))
        }
        completionHandler = nil
    }
}

final class LockedText: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""

    func append(_ text: String) {
        lock.lock()
        value += text
        lock.unlock()
    }

    func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func take() -> String {
        lock.lock()
        defer { lock.unlock() }
        let result = value
        value.removeAll(keepingCapacity: true)
        return result
    }
}

private struct CPUTickSnapshot {
    let user: UInt64
    let system: UInt64
    let idle: UInt64
    let nice: UInt64

    var total: UInt64 { user + system + idle + nice }
    var busy: UInt64 { user + system + nice }
}

enum TranscriberError: LocalizedError {
    case noAudioTrack
    case readerSetup
    case readerFailed(String)
    case writerSetup
    case writerFailed(String)
    case runtimeMissing
    case mediaRuntimeMissing
    case runtimeIncompatible
    case modelMissing
    case processFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack: return "No audio track was found in this file."
        case .readerSetup: return "Could not prepare the source recording."
        case .readerFailed(let detail): return "Audio decoding failed: \(detail)"
        case .writerSetup: return "Could not create the temporary WAV file."
        case .writerFailed(let detail): return "Audio conversion failed: \(detail)"
        case .runtimeMissing: return "The bundled transcription runtime is missing. Reinstall the app."
        case .mediaRuntimeMissing: return "The bundled media decoder is missing. Reinstall the app."
        case .runtimeIncompatible: return "The bundled transcription engine and its runtime policy are incompatible. Reinstall or update the app."
        case .modelMissing: return "The large-v3 model is not installed."
        case .processFailed(let code): return "The transcription engine exited with status \(code)."
        }
    }
}

@MainActor
final class TranscriberModel: ObservableObject {
    @Published var recordings: [URL] = []
    @Published var logText = "Drop recordings here or choose files to begin."
    @Published var statusText = "Ready"
    @Published var isRunning = false
    @Published var lastOutput: URL?
    @Published var modelInstalled = false
    @Published var selectedProfileID = ModelProfile.maximum.id
    @Published var isInstalling = false
    @Published var installProgress = 0.0
    @Published var installStatus = "Model not installed"
    @Published var selectedLanguage = "en"
    @Published var optimizationText = "Automatic scheduling will adapt to this Mac and the queue."

    let hardware = HardwareProfile.current()
    private var processes: [UUID: Process] = [:]
    private var transcriptionTask: Task<Void, Never>?
    private var downloader: ModelDownloader?
    private var previousCPUTicks: CPUTickSnapshot?

    var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Transcriber", isDirectory: true)
    }

    var selectedProfile: ModelProfile {
        ModelProfile.all.first(where: { $0.id == selectedProfileID }) ?? .maximum
    }

    func modelURL(for profile: ModelProfile) -> URL {
        applicationSupport.appendingPathComponent("models", isDirectory: true).appendingPathComponent(profile.filename)
    }

    func checksumMarkerURL(for profile: ModelProfile) -> URL {
        applicationSupport.appendingPathComponent("models", isDirectory: true).appendingPathComponent("\(profile.filename).sha256")
    }

    var installedModelURL: URL {
        modelURL(for: selectedProfile)
    }

    var checksumMarkerURL: URL {
        checksumMarkerURL(for: selectedProfile)
    }

    var bundledRuntime: URL {
        Bundle.main.resourceURL!.appendingPathComponent("runtime/bin", isDirectory: true)
    }

    var bundledWhisper: URL {
        bundledRuntime.appendingPathComponent("whisper-cli")
    }

    var bundledFFmpeg: URL {
        bundledRuntime.appendingPathComponent("ffmpeg")
    }

    var legacyModelURL: URL? {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let oldSupport = base.appendingPathComponent("LectureTranscriber/models/\(selectedProfile.filename)")
        if FileManager.default.fileExists(atPath: oldSupport.path) { return oldSupport }
        guard selectedProfile.id == ModelProfile.maximum.id else { return nil }
        let oldBundle = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("runtime/model/\(ModelProfile.maximum.filename)")
        return FileManager.default.fileExists(atPath: oldBundle.path) ? oldBundle : nil
    }

    init() {
        selectedProfileID = hardware.recommendedProfileID
        refreshInstallationState()
    }

    func selectProfile(_ id: String) {
        guard !isRunning, !isInstalling else { return }
        selectedProfileID = id
        refreshInstallationState()
    }

    func profileIsInstalled(_ profile: ModelProfile) -> Bool {
        let marker = try? String(contentsOf: checksumMarkerURL(for: profile), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return FileManager.default.fileExists(atPath: modelURL(for: profile).path) && marker == profile.sha256
    }

    var installedProfiles: [ModelProfile] {
        ModelProfile.all.filter(profileIsInstalled)
    }

    var installedStorageText: String {
        let bytes = installedProfiles.reduce(Int64(0)) { total, profile in
            let attributes = try? FileManager.default.attributesOfItem(atPath: modelURL(for: profile).path)
            return total + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
        }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    func refreshInstallationState() {
        let profile = selectedProfile
        modelInstalled = profileIsInstalled(profile)
        if modelInstalled {
            installStatus = "\(profile.name) installed"
        } else if legacyModelURL != nil {
            installStatus = "Existing model found — ready to import"
        } else {
            installStatus = "Requires a \(profile.downloadSize) download"
        }
    }

    func installRecommendedModel() {
        guard !isInstalling else { return }
        let profile = selectedProfile
        isInstalling = true
        installProgress = 0
        installStatus = legacyModelURL == nil ? "Downloading \(profile.name)..." : "Importing existing \(profile.name)..."

        if let legacy = legacyModelURL {
            Task {
                await installModelFile(from: legacy, removeSource: false, profile: profile)
            }
            return
        }

        let downloader = ModelDownloader()
        self.downloader = downloader
        downloader.progressHandler = { [weak self] progress in
            Task { @MainActor in
                self?.installProgress = progress
                self?.installStatus = "Downloading \(profile.name) — \(Int(progress * 100))%"
            }
        }
        downloader.completionHandler = { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let temporaryFile):
                    self.installStatus = "Verifying model checksum..."
                    await self.installModelFile(from: temporaryFile, removeSource: true, profile: profile)
                case .failure(let error):
                    self.isInstalling = false
                    self.installStatus = "Install failed: \(error.localizedDescription)"
                }
                self.downloader = nil
            }
        }
        downloader.start(url: profile.downloadURL)
    }

    func cancelInstall() {
        downloader?.cancel()
        downloader = nil
        isInstalling = false
        refreshInstallationState()
    }

    func verifyModel() {
        guard modelInstalled, !isInstalling else { return }
        isInstalling = true
        installStatus = "Verifying model checksum..."
        let profile = selectedProfile
        let modelURL = installedModelURL
        Task {
            do {
                let digest = try await Task.detached { try Self.sha256(of: modelURL) }.value
                if digest == profile.sha256 {
                    installStatus = "\(profile.name) verified"
                } else {
                    modelInstalled = false
                    installStatus = "Checksum mismatch — reinstall required"
                }
            } catch {
                installStatus = "Verification failed: \(error.localizedDescription)"
            }
            isInstalling = false
        }
    }

    func removeModel() {
        guard !isRunning, !isInstalling else { return }
        do {
            if FileManager.default.fileExists(atPath: installedModelURL.path) {
                try FileManager.default.removeItem(at: installedModelURL)
            }
            if FileManager.default.fileExists(atPath: checksumMarkerURL.path) {
                try FileManager.default.removeItem(at: checksumMarkerURL)
            }
            refreshInstallationState()
        } catch {
            installStatus = "Could not remove model: \(error.localizedDescription)"
        }
    }

    func revealModel() {
        guard modelInstalled else { return }
        NSWorkspace.shared.activateFileViewerSelecting([installedModelURL])
    }

    func copyModelPath() {
        guard modelInstalled else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(installedModelURL.path, forType: .string)
        installStatus = "Model path copied"
    }

    private func installModelFile(from source: URL, removeSource: Bool, profile: ModelProfile) async {
        do {
            let digest = try await Task.detached { try Self.sha256(of: source) }.value
            guard digest == profile.sha256 else {
                throw NSError(domain: "Transcriber", code: 2, userInfo: [NSLocalizedDescriptionKey: "Checksum mismatch. The downloaded file was rejected."])
            }
            let destination = modelURL(for: profile)
            let marker = checksumMarkerURL(for: profile)
            let modelsDirectory = destination.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
            let staging = modelsDirectory.appendingPathComponent(".\(profile.filename).installing")
            if FileManager.default.fileExists(atPath: staging.path) { try FileManager.default.removeItem(at: staging) }
            do {
                try FileManager.default.linkItem(at: source, to: staging)
            } catch {
                try FileManager.default.copyItem(at: source, to: staging)
            }
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: staging, to: destination)
            try (profile.sha256 + "\n").write(to: marker, atomically: true, encoding: .utf8)
            if removeSource { try? FileManager.default.removeItem(at: source) }
            modelInstalled = selectedProfile.id == profile.id
            installProgress = 1
            installStatus = "\(profile.name) installed and verified"
        } catch {
            installStatus = "Install failed: \(error.localizedDescription)"
        }
        isInstalling = false
    }

    nonisolated private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 8 * 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func addRecordings(_ urls: [URL]) {
        let files = urls.filter { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
        for file in files where !recordings.contains(file) {
            recordings.append(file)
        }
        if !files.isEmpty && !isRunning {
            statusText = "Ready to transcribe \(recordings.count) file\(recordings.count == 1 ? "" : "s")"
        }
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.title = "Choose media files"
        panel.prompt = "Add"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.data]
        if panel.runModal() == .OK { addRecordings(panel.urls) }
    }

    func removeRecording(_ url: URL) {
        guard !isRunning else { return }
        recordings.removeAll { $0 == url }
        statusText = recordings.isEmpty ? "Ready" : "Ready to transcribe \(recordings.count) file\(recordings.count == 1 ? "" : "s")"
    }

    func clear() {
        guard !isRunning else { return }
        recordings.removeAll()
        lastOutput = nil
        logText = "Drop recordings here or choose files to begin."
        statusText = "Ready"
    }

    func start() {
        guard modelInstalled, !isRunning, !recordings.isEmpty else { return }
        startRun(profiles: [selectedProfile], benchmark: false)
    }

    func startBenchmark() {
        let profiles = installedProfiles
        guard profiles.count >= 2, !isRunning, !recordings.isEmpty else { return }
        startRun(profiles: profiles, benchmark: true)
    }

    private func startRun(profiles: [ModelProfile], benchmark: Bool) {
        guard FileManager.default.isExecutableFile(atPath: bundledWhisper.path) else {
            statusText = TranscriberError.runtimeMissing.localizedDescription
            return
        }
        guard FileManager.default.isExecutableFile(atPath: bundledFFmpeg.path) else {
            statusText = TranscriberError.mediaRuntimeMissing.localizedDescription
            return
        }
        guard runtimeIsCompatible() else {
            statusText = TranscriberError.runtimeIncompatible.localizedDescription
            return
        }
        isRunning = true
        lastOutput = nil
        logText = "Transcription started. Detailed engine output is saved with each result."
        statusText = "Starting..."
        let queued = recordings
        transcriptionTask = Task {
            do {
                primeCPUUtilization()
                try await Task.sleep(nanoseconds: 250_000_000)
                for (profileIndex, profile) in profiles.enumerated() {
                    var nextIndex = 0
                    var completed = 0
                    var active = 0
                    let concurrencyCeiling = makeConcurrencyCeiling(profile: profile)
                    try await withThrowingTaskGroup(of: URL.self) { group in
                        var plan = makeExecutionPlan(remainingFiles: queued.count, profile: profile, concurrencyCeiling: concurrencyCeiling)
                        optimizationText = plan.reason

                        while active < plan.concurrency && nextIndex < queued.count {
                            let recording = queued[nextIndex]
                            let jobPlan = plan
                            nextIndex += 1
                            active += 1
                            group.addTask { try await self.transcribe(recording, plan: jobPlan, profile: profile, benchmark: benchmark) }
                        }

                        let initialPrefix = benchmark ? "Bench \(profileIndex + 1)/\(profiles.count) · \(profile.name) · " : ""
                        statusText = "\(initialPrefix)0/\(queued.count) complete · \(active) active"

                        while let output = try await group.next() {
                            active -= 1
                            completed += 1
                            lastOutput = output.appendingPathComponent("transcript.txt")
                            try Task.checkCancellation()

                            let remaining = queued.count - completed
                            guard remaining > 0 else { continue }
                            plan = makeExecutionPlan(remainingFiles: remaining, profile: profile, concurrencyCeiling: concurrencyCeiling)
                            optimizationText = plan.reason
                            while active < plan.concurrency && nextIndex < queued.count {
                                let recording = queued[nextIndex]
                                let jobPlan = plan
                                nextIndex += 1
                                active += 1
                                group.addTask { try await self.transcribe(recording, plan: jobPlan, profile: profile, benchmark: benchmark) }
                            }

                            let prefix = benchmark ? "Bench \(profileIndex + 1)/\(profiles.count) · \(profile.name) · " : ""
                            statusText = "\(prefix)\(completed)/\(queued.count) complete · \(active) active"
                        }
                    }
                }
                statusText = benchmark ? "Benchmark completed" : "Completed"
                NSSound(named: "Glass")?.play()
            } catch is CancellationError {
                statusText = "Cancelled"
            } catch {
                statusText = "Failed — \(error.localizedDescription)"
                appendLog("\nERROR: \(error.localizedDescription)\n")
            }
            isRunning = false
            processes.removeAll()
            transcriptionTask = nil
        }
    }

    func cancel() {
        statusText = "Cancelling..."
        transcriptionTask?.cancel()
        for process in processes.values where process.isRunning { process.terminate() }
    }

    func revealOutput() {
        guard let lastOutput else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastOutput])
    }

    private func appendLog(_ text: String) {
        logText += text
        if logText.count > 12_000 { logText.removeFirst(logText.count - 12_000) }
    }

    private func transcribe(_ input: URL, plan: ExecutionPlan, profile: ModelProfile, benchmark: Bool) async throws -> URL {
        let jobID = UUID()
        let fileManager = FileManager.default
        let inputDirectory = input.deletingLastPathComponent()
        let stem = input.deletingPathExtension().lastPathComponent
        let outputName = benchmark ? "\(stem).benchmark-\(profile.id).transcript" : "\(stem).transcript"
        var outputDirectory = inputDirectory.appendingPathComponent(outputName, isDirectory: true)
        if fileManager.fileExists(atPath: outputDirectory.path) {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            outputDirectory = inputDirectory.appendingPathComponent("\(outputName)-\(formatter.string(from: Date()))", isDirectory: true)
        }

        let scratch = fileManager.temporaryDirectory.appendingPathComponent("transcriber-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }
        let wav = scratch.appendingPathComponent("audio.wav")
        let outputStem = scratch.appendingPathComponent("transcript")

        appendLog("\nTranscribing: \(input.lastPathComponent)\nStep 1/2: extracting the first audio stream...\n")
        let mediaLog = try await runFFmpeg(input: input, output: wav, jobID: jobID)
        try Task.checkCancellation()
        appendLog("Step 2/2: running bundled large-v3...\n\n")

        let started = Date()
        let engineLog = try await runWhisper(wav: wav, outputStem: outputStem, plan: plan, profile: profile, jobID: jobID)
        let elapsed = Date().timeIntervalSince(started)
        try Task.checkCancellation()

        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        for ext in ["txt", "srt", "json"] {
            try fileManager.moveItem(at: outputStem.appendingPathExtension(ext), to: outputDirectory.appendingPathComponent("transcript.\(ext)"))
        }
        try engineLog.write(to: outputDirectory.appendingPathComponent("run.log"), atomically: true, encoding: .utf8)
        let metadata = """
        # High-fidelity lecture transcript

        - Source: `\(input.path)`
        - Processing time: `\(String(format: "%.1f", elapsed)) seconds`
        - Hardware: `\(hardware.chip), \(hardware.memoryGiB) GiB, \(hardware.logicalCores) logical cores, \(hardware.performanceCores) performance cores`
        - Profile: \(profile.name)
        - Model: \(profile.filename)
        - Model path: `\(modelURL(for: profile).path)`
        - Benchmark run: \(benchmark ? "yes" : "no")
        - Decoder: Metal, beam 5, \(plan.threadsPerFile) CPU threads, VAD off, no prompt, previous-window context off
        - Runtime policy: v\(RuntimePolicy.bundled.policyVersion), compatible with \(RuntimePolicy.bundled.engine) \(RuntimePolicy.bundled.compatibleVersionContains)x
        - Effective arguments: `\(resolvedWhisperArguments(wav: wav, outputStem: outputStem, profile: profile, threads: plan.threadsPerFile).joined(separator: " "))`
        - Engine environment: `\(RuntimePolicy.bundled.environment.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "))`
        - Scheduler: \(plan.concurrency) Metal inference worker(s); concurrency and CPU helper threads selected from the model, performance cores, GPU/CPU load, memory, power, and thermal state
        - Temporary PCM: deleted
        - Media decoder: bundled FFmpeg (first audio stream)
        """
        try metadata.write(to: outputDirectory.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try mediaLog.write(to: outputDirectory.appendingPathComponent("media.log"), atomically: true, encoding: .utf8)
        appendLog("\nCompleted: \(outputDirectory.appendingPathComponent("transcript.txt").path)\n")
        return outputDirectory
    }

    private func runFFmpeg(input: URL, output: URL, jobID: UUID) async throws -> String {
        let collector = LockedText()
        let task = Process()
        let pipe = Pipe()
        task.executableURL = bundledFFmpeg
        task.arguments = [
            "-nostdin", "-hide_banner", "-loglevel", "info", "-y",
            "-i", input.path,
            "-map", "0:a:0", "-vn", "-sn", "-dn",
            "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", output.path,
        ]
        task.standardOutput = pipe
        task.standardError = pipe
        processes[jobID] = task
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            collector.append(text)
        }
        let status: Int32 = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                task.terminationHandler = { completed in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(returning: completed.terminationStatus)
                }
                do { try task.run() } catch { continuation.resume(throwing: error) }
            }
        }, onCancel: {
            if task.isRunning { task.terminate() }
        })
        processes.removeValue(forKey: jobID)
        if Task.isCancelled { throw CancellationError() }
        guard status == 0, FileManager.default.fileExists(atPath: output.path) else {
            throw TranscriberError.noAudioTrack
        }
        return collector.snapshot()
    }

    private func runWhisper(wav: URL, outputStem: URL, plan: ExecutionPlan, profile: ModelProfile, jobID: UUID) async throws -> String {
        let activeModelURL = modelURL(for: profile)
        guard FileManager.default.fileExists(atPath: activeModelURL.path) else { throw TranscriberError.modelMissing }
        let collector = LockedText()
        let task = Process()
        let pipe = Pipe()
        task.executableURL = bundledWhisper
        task.arguments = resolvedWhisperArguments(wav: wav, outputStem: outputStem, profile: profile, threads: plan.threadsPerFile)
        task.standardOutput = pipe
        task.standardError = pipe
        let runtimeEnvironment = RuntimePolicy.bundled.environment.merging(["DYLD_LIBRARY_PATH": bundledRuntime.path]) { _, new in new }
        task.environment = ProcessInfo.processInfo.environment.merging(runtimeEnvironment) { _, new in new }
        processes[jobID] = task
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            collector.append(text)
        }

        let status: Int32 = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                task.terminationHandler = { completed in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(returning: completed.terminationStatus)
                }
                do { try task.run() } catch { continuation.resume(throwing: error) }
            }
        }, onCancel: {
            if task.isRunning { task.terminate() }
        })
        processes.removeValue(forKey: jobID)
        if Task.isCancelled { throw CancellationError() }
        guard status == 0 else { throw TranscriberError.processFailed(status) }
        return collector.snapshot()
    }

    private func resolvedWhisperArguments(wav: URL, outputStem: URL, profile: ModelProfile, threads: Int) -> [String] {
        let replacements = [
            "{model}": modelURL(for: profile).path,
            "{file}": wav.path,
            "{language}": selectedLanguage,
            "{threads}": String(threads),
            "{output}": outputStem.path,
        ]
        return RuntimePolicy.bundled.arguments.map { replacements[$0] ?? $0 }
    }

    private func makeConcurrencyCeiling(profile: ModelProfile) -> Int {
        guard profile.id == ModelProfile.balanced.id,
              Self.availableMemoryGiB() >= 7.0,
              !ProcessInfo.processInfo.isLowPowerModeEnabled,
              ProcessInfo.processInfo.thermalState != .serious,
              ProcessInfo.processInfo.thermalState != .critical else { return 1 }
        guard let gpu = Self.gpuUtilization(), gpu < 0.50 else { return 1 }
        return 2
    }

    private func makeExecutionPlan(remainingFiles: Int, profile: ModelProfile, concurrencyCeiling: Int) -> ExecutionPlan {
        let availableGiB = Self.availableMemoryGiB()
        let reservePerJob: Double
        switch profile.id {
        case ModelProfile.maximum.id: reservePerJob = 4.25
        case ModelProfile.balanced.id: reservePerJob = 2.5
        default: reservePerJob = 1.5
        }
        let cpuUtilization = sampleCPUUtilization()
        let thermal = ProcessInfo.processInfo.thermalState
        let constrained = ProcessInfo.processInfo.isLowPowerModeEnabled || thermal == .serious || thermal == .critical
        let cpuBusy = (cpuUtilization ?? 0) > 0.90
        let memorySlots = max(1, Int(max(0, availableGiB - 2.0) / reservePerJob))
        let concurrency = constrained || cpuBusy ? 1 : max(1, min(remainingFiles, min(memorySlots, concurrencyCeiling)))
        let baseThreads = max(2, min(8, hardware.performanceCores))
        let threads = constrained || cpuBusy ? max(2, baseThreads - 1) : baseThreads
        let memorySafe = availableGiB >= reservePerJob + 1.0
        let state: String
        if constrained {
            state = "power/thermal protection active"
        } else if cpuBusy {
            state = "high system CPU load; helper threads reduced"
        } else if !memorySafe {
            state = "low memory headroom; serial GPU mode"
        } else if concurrency > 1 {
            state = "dual workers validated for this model"
        } else {
            state = "serial Metal mode avoids GPU contention"
        }
        let cpuText = cpuUtilization.map { " · CPU \(Int($0 * 100))%" } ?? ""
        let queueText = remainingFiles > 1 ? " · \(remainingFiles) queued" : ""
        let reason = "Automatic: \(concurrency) Metal worker\(concurrency == 1 ? "" : "s") × \(threads) performance-core threads · \(String(format: "%.1f", availableGiB)) GiB available\(cpuText)\(queueText) · \(state)"
        return ExecutionPlan(concurrency: concurrency, threadsPerFile: threads, reason: reason)
    }

    private func sampleCPUUtilization() -> Double? {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &load) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let current = CPUTickSnapshot(
            user: UInt64(load.cpu_ticks.0),
            system: UInt64(load.cpu_ticks.1),
            idle: UInt64(load.cpu_ticks.2),
            nice: UInt64(load.cpu_ticks.3)
        )
        defer { previousCPUTicks = current }
        guard let previous = previousCPUTicks,
              current.total > previous.total,
              current.busy >= previous.busy else { return nil }
        return Double(current.busy - previous.busy) / Double(current.total - previous.total)
    }

    private func primeCPUUtilization() {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &load) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        previousCPUTicks = CPUTickSnapshot(
            user: UInt64(load.cpu_ticks.0),
            system: UInt64(load.cpu_ticks.1),
            idle: UInt64(load.cpu_ticks.2),
            nice: UInt64(load.cpu_ticks.3)
        )
    }

    nonisolated private static func availableMemoryGiB() -> Double {
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        }
        let pages = UInt64(statistics.free_count + statistics.inactive_count + statistics.speculative_count + statistics.purgeable_count)
        return Double(pages * UInt64(pageSize)) / 1_073_741_824.0
    }

    nonisolated private static func gpuUtilization() -> Double? {
        guard let matching = IOServiceMatching("AGXAccelerator") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        let service = IOIteratorNext(iterator)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let property = IORegistryEntryCreateCFProperty(
            service,
            "PerformanceStatistics" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? [String: Any],
              let utilization = property["Device Utilization %"] as? NSNumber else { return nil }
        return min(1.0, max(0.0, utilization.doubleValue / 100.0))
    }

    private func runtimeIsCompatible() -> Bool {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = bundledWhisper
        task.arguments = ["--version"]
        task.standardOutput = pipe
        task.standardError = pipe
        task.environment = ProcessInfo.processInfo.environment.merging(["DYLD_LIBRARY_PATH": bundledRuntime.path]) { _, new in new }
        do {
            try task.run()
            task.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return task.terminationStatus == 0 && output.contains(RuntimePolicy.bundled.compatibleVersionContains)
        } catch {
            return false
        }
    }
}

struct HardwareCard: View {
    let profile: HardwareProfile

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 30))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(profile.chip) · \(profile.memoryGiB) GiB · \(profile.logicalCores) logical cores (\(profile.performanceCores) performance)")
                    .font(.headline)
                Text("Recommended: \(profile.recommendation)")
                    .font(.subheadline.weight(.medium))
                Text(profile.details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.07)))
    }
}

struct SetupCard: View {
    @ObservedObject var model: TranscriberModel
    @State private var confirmsRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: model.modelInstalled ? "checkmark.seal.fill" : "arrow.down.circle")
                    .foregroundStyle(model.modelInstalled ? .green : Color.accentColor)
                Text("Capability & Model").font(.headline)
                Spacer()
                Text(model.installStatus).font(.caption).foregroundStyle(.secondary)
            }

            if !model.installedProfiles.isEmpty {
                Text("Installed storage: \(model.installedStorageText) across \(model.installedProfiles.count) model\(model.installedProfiles.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Picker("Capability", selection: Binding(
                get: { model.selectedProfileID },
                set: { model.selectProfile($0) }
            )) {
                ForEach(ModelProfile.all) { profile in
                    Text(profile.name).tag(profile.id)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.isInstalling || model.isRunning)

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(model.selectedProfile.name).font(.subheadline.weight(.semibold))
                        if model.selectedProfile.id == model.hardware.recommendedProfileID {
                            Text("RECOMMENDED")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                                .foregroundStyle(Color.accentColor)
                        }
                        if model.profileIsInstalled(model.selectedProfile) {
                            Label("Installed", systemImage: "checkmark.circle.fill")
                                .font(.caption).foregroundStyle(.green)
                        }
                    }
                    Text(model.selectedProfile.subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(model.selectedProfile.downloadSize).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }

            if model.isInstalling {
                ProgressView(value: model.installProgress)
                HStack {
                    Text(model.installProgress > 0 ? "\(Int(model.installProgress * 100))%" : "Preparing...")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { model.cancelInstall() }
                }
            } else if model.modelInstalled {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Model path").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    HStack {
                        Text(model.installedModelURL.path)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                        Spacer()
                    }
                    HStack {
                        Button("Show in Finder") { model.revealModel() }
                        Button("Copy Path") { model.copyModelPath() }
                        Spacer()
                        Button("Verify") { model.verifyModel() }
                        Button("Remove…", role: .destructive) { confirmsRemoval = true }
                    }
                }
            } else {
                HStack {
                    Text("The app installs this model into your user Application Support folder. No Homebrew or Python is required.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(model.legacyModelURL == nil ? "Install \(model.selectedProfile.name)" : "Import Existing Model") {
                        model.installRecommendedModel()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(14)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.25)))
        .alert("Remove \(model.selectedProfile.name)?", isPresented: $confirmsRemoval) {
            Button("Cancel", role: .cancel) {}
            Button("Remove Model", role: .destructive) { model.removeModel() }
        } message: {
            Text("This deletes \(model.selectedProfile.downloadSize) from:\n\(model.installedModelURL.path)\n\nYou can reinstall it later from this app.")
        }
    }
}

struct DropZone: View {
    let disabled: Bool
    let onFiles: ([URL]) -> Void
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: "arrow.down.doc.fill")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(targeted ? Color.accentColor : .secondary)
            Text("Drop media files here").font(.headline)
            Text("Audio, video, screen recordings, and other files with an extractable audio stream")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 115)
        .background(RoundedRectangle(cornerRadius: 14).fill(targeted ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [7])))
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $targeted) { providers in
            guard !disabled else { return false }
            for provider in providers {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    DispatchQueue.main.async { onFiles([url]) }
                }
            }
            return true
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: TranscriberModel
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "waveform.and.mic").font(.title2).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Transcriber").font(.title2.bold())
                    Text("Private, local, high-fidelity transcription").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(model.statusText).font(.callout.weight(.medium)).foregroundStyle(model.isRunning ? Color.accentColor : .secondary)
            }
            .padding(.horizontal, 22).padding(.vertical, 15)
            Divider()
            TabView(selection: $selectedTab) {
                TranscribeView(model: model, openModels: { selectedTab = 1 })
                    .tabItem { Label("Transcribe", systemImage: "waveform") }.tag(0)
                ModelsView(model: model)
                    .tabItem { Label("Models", systemImage: "shippingbox") }.tag(1)
            }
            .padding(18)
        }
        .frame(minWidth: 800, minHeight: 700)
        .onReceive(NotificationCenter.default.publisher(for: .transcriberOpenFiles)) { note in
            if let urls = note.object as? [URL] { model.addRecordings(urls) }
        }
    }
}

struct TranscribeView: View {
    @ObservedObject var model: TranscriberModel
    let openModels: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(model.selectedProfile.name, systemImage: model.modelInstalled ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(model.modelInstalled ? .green : .orange)
                Text(model.modelInstalled ? "Ready" : "Model required").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Manage Models…", action: openModels)
            }
            HStack(spacing: 14) {
                Label(model.optimizationText, systemImage: "gauge.with.dots.needle.67percent")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Picker("Language", selection: $model.selectedLanguage) {
                    ForEach(LanguageOption.all) { language in
                        Text("\(language.name) (\(language.code))").tag(language.code)
                    }
                }.frame(width: 245).disabled(model.isRunning)
            }
            if model.selectedLanguage == "auto" {
                Text("Auto detects one dominant language for the whole file; frequent language switching may be less reliable.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            DropZone(disabled: model.isRunning, onFiles: model.addRecordings)
            HStack {
                Button("Choose Files…") { model.chooseFiles() }.disabled(model.isRunning)
                Button("Clear Queue") { model.clear() }.disabled(model.isRunning || model.recordings.isEmpty)
                Spacer()
                if model.isRunning {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { model.cancel() }
                } else {
                    Button("Bench Installed Models") { model.startBenchmark() }
                        .disabled(model.recordings.isEmpty || model.installedProfiles.count < 2)
                        .help("Transcribe the entire queue with every installed model for side-by-side quality review")
                    Button("Transcribe \(model.recordings.isEmpty ? "" : "(\(model.recordings.count))")") { model.start() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.recordings.isEmpty || !model.modelInstalled)
                        .keyboardShortcut(.return, modifiers: [.command])
                }
            }
            GroupBox("Queue") {
                if model.recordings.isEmpty {
                    Text("No files queued").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 70)
                } else {
                    List(model.recordings, id: \.self) { url in
                        HStack(spacing: 10) {
                            Image(systemName: "film.stack").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(url.lastPathComponent).lineLimit(1)
                                Text(url.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button { model.removeRecording(url) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.secondary).disabled(model.isRunning)
                        }
                    }.frame(minHeight: 90, maxHeight: 150)
                }
            }
            GroupBox("Activity summary") {
                ScrollView {
                    Text(model.logText).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading).padding(8)
                }.frame(minHeight: 115)
            }
            HStack {
                Text("Each result is saved beside its source; temporary extracted audio is deleted.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reveal Last Output") { model.revealOutput() }.disabled(model.lastOutput == nil)
            }
        }
    }
}

struct ModelsView: View {
    @ObservedObject var model: TranscriberModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                Text("Performance & Models").font(.title2.bold())
                Text("Choose recognition capability first. Transcriber recommends the highest-fidelity profile suitable for this Mac.")
                    .foregroundStyle(.secondary)
                HardwareCard(profile: model.hardware)
                SetupCard(model: model)
            }.padding(.horizontal, 2)
        }
    }
}

@main
struct TranscriberApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = TranscriberModel()

    var body: some Scene {
        Window("Transcriber", id: "main") { ContentView(model: model) }
            .windowStyle(.titleBar)
            .defaultSize(width: 840, height: 740)
    }
}
