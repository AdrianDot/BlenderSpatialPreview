import Foundation
import os
import SpatialPreview
import USDKit

/// Holds the open USD stage and the Spatial Preview session, and answers the one
/// question Blender asks: show this scene on the headset.
///
/// Blender drives everything. Every command is answered only once the outcome is known,
/// so Blender can report the truth in its own sidebar and this window can stay closed.
///
/// Every event is appended to ~/Library/Logs/SpatialPreviewBridge/bridge.jsonl.
@MainActor
@Observable
final class BridgeModel {

    /// The listener callback is not actor-isolated, so it needs a way back in.
    @ObservationIgnored nonisolated(unsafe) static var shared: BridgeModel?

    private(set) var log: [String] = []
    /// What to say while there is no session: idle, no device, failed, closed. Once a
    /// session exists, `sessionLine` shows Apple's state instead.
    private(set) var sessionState = "idle"

    // Read straight from Apple's objects, never copied. All three are Observable, so
    // Apple tells the window when they change - a copy taken at send time went stale
    // the moment the headset was closed or disconnected.
    var endpointAvailable: Bool { observer.isEndpointAvailable }
    var isSessionRunning: Bool { session?.state == .connected }
    var sessionLine: String { session.map { "\($0.state)" } ?? sessionState }
    var progressLine: String {
        guard let progress = session?.progress else { return "—" }
        return "\(progress.completedCount) / \(progress.totalCount.map(String.init) ?? "?")"
    }

    /// A failure the window must keep showing, because `sessionState` is overwritten
    /// by the next send.
    private(set) var problem: String?

    /// Something that will reach the headset and look wrong there. Distinct from
    /// `problem`, which means nothing reached it at all.
    private(set) var warning: String?

    /// Raised when a send had no device to go to. The window presents Apple's picker
    /// itself rather than waiting for someone to find the button.
    var showDevicePicker = false

    private(set) var sceneName = ""
    private(set) var sceneVertices = 0
    private(set) var sceneMeshes = 0
    private(set) var sceneBytes = 0

    /// How the last session found its headset: already connected, or picked. Apple's
    /// endpoint has no name, only an id nobody can read off the headset, so the id goes
    /// to the log (`endpoint_resolved`) and not the window.
    private(set) var deviceLabel = ""
    private(set) var optimizationInUse = BridgeModel.optimizationLabel

    var stagePath = ""

    /// Raised when there is no device to send to, as opposed to a device that refused.
    struct NoEndpoint: Error {}

    static let optimization = USDPreviewSession.OptimizationParameters
        .processed([.optimized, .compressed])
    /// Read-only, so the window can say what Apple is doing to the scene on the way out.
    static let optimizationLabel = "Apple optimizer + compression"

    /// Apple's `start` has no timeout of its own, and has been seen never returning at
    /// all - which froze Blender, because Blender waits for this answer. Comfortably
    /// inside Blender's own 180 s so the answer is ours, with a reason, not its timeout.
    static let startDeadline = Duration.seconds(150)

    struct TimedOut: Error {}

    /// `body` or the deadline, whichever comes first; `TimedOut` if the deadline.
    ///
    /// Not a task group: a group waits for every child before it returns, so a `body`
    /// that ignores cancellation - the one case a deadline is for - held the deadline
    /// hostage with it. Here the loser is cancelled and left to finish on its own.
    static func withDeadline<T: Sendable>(_ limit: Duration,
                                          _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let first = FirstResult(continuation)
            let work = Task {
                do { first.resume(.success(try await body())) }
                catch { first.resume(.failure(error)) }
            }
            Task {
                try? await Task.sleep(for: limit)
                if first.resume(.failure(TimedOut())) { work.cancel() }
            }
        }
    }

    private let observer = ConnectedSpatialEndpointObserver()

    /// Chosen in the picker during this run, and kept for as long as the app runs.
    /// Never written to disk: a saved endpoint goes stale, and a stale one is worse than
    /// no endpoint at all because the session starts against it and reports success.
    private var pickedEndpoint: SpatialPreviewEndpoint?

    private var stage: USDStage?
    private var session: USDPreviewSession?
    private var delegateBox: ChangeLogger?
    private var eventTask: Task<Void, Never>?

    /// Two files at most, so the log never grows without bound - but rotated by size,
    /// not by launch. Rotating on every launch threw away the runs that mattered: the
    /// app is quit and reopened constantly, and a bug is usually reported afterwards.
    private let logURL: URL? = {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/SpatialPreviewBridge", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let current = dir.appendingPathComponent("bridge.jsonl")
        let size = (try? current.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > 5_000_000 {
            let previous = dir.appendingPathComponent("bridge.previous.jsonl")
            try? fm.removeItem(at: previous)
            try? fm.moveItem(at: current, to: previous)
        }
        return current
    }()
    private var listener: BridgeListener?

    init() {
        // USDKit emits an os_signpost on stage creation; on this beta that crashes if it
        // is the first signpost in the process. Emitting one log line first avoids it.
        Logger(subsystem: "dev.adrian.spatialpreviewbridge", category: "warmup")
            .log(level: .default, "warmup \(1, privacy: .public)")
        startListening()
    }

    // MARK: - Commands from Blender

    private func startListening() {
        let listener = BridgeListener(onCommand: { command, reply in
            Task { @MainActor in BridgeModel.shared?.handle(command, reply: reply) }
        }, onStateChange: { state in
            Task { @MainActor in BridgeModel.shared?.note("listener_state", ["state": state]) }
        })
        do {
            try listener.start()
            self.listener = listener
            note("listening", ["port": BridgeListener.port])
        } catch {
            note("listen_failed", ["error": "\(error)"])
        }
        BridgeModel.shared = self
    }

    /// Three commands, and each is answered once its outcome is settled - a send is not
    /// acknowledged until the headset has the scene or has refused it. One question, one
    /// truthful answer, and no polling loop on Blender's side to discover which.
    func handle(_ command: [String: Any], reply: @escaping @Sendable ([String: Any]) -> Void) {
        let cmd = command["cmd"] as? String ?? ""
        note("command", ["cmd": cmd])
        switch cmd {
        case "open_and_start":
            guard let path = command["path"] as? String else {
                var row = statusPayload()
                row["problem"] = "the send carried no file path"
                reply(row)
                return
            }
            stagePath = path
            loadStage()
            if problem != nil { reply(statusPayload()); return }
            // `unmodified` is a diagnostic, not a setting: it skips Apple's optimizer so
            // a scene that arrives wrong can be compared against one Apple has not
            // touched. Deliberately absent from the window - there is no reason to use it
            // except to find out whose side a problem is on.
            startSession(unmodified: command["unmodified"] as? Bool ?? false) { [weak self] in
                reply(MainActor.assumeIsolated { self?.statusPayload() } ?? [:])
            }
        case "close":
            closeSession()
            reply(statusPayload())
        case "status":
            reply(statusPayload())
        default:
            note("command_unknown", ["cmd": cmd])
            var row = statusPayload()
            row["problem"] = "unknown command: \(cmd)"
            reply(row)
        }
    }

    /// What Blender's sidebar draws.
    func statusPayload() -> [String: Any] {
        var row: [String: Any] = [
            "ok": problem == nil,
            "state": sessionLine,
            "running": isSessionRunning,
            "endpoint": endpointAvailable || pickedEndpoint != nil,
            "device": deviceLabel,
            "scene": sceneName,
            "vertices": sceneVertices,
            "meshes": sceneMeshes,
            "bytes": sceneBytes,
        ]
        if let problem { row["problem"] = problem }
        if let warning { row["warning"] = warning }
        if showDevicePicker {
            // Read under `problem` in Blender's sidebar, as the second line of one
            // sentence: "no headset yet - pick your Vision Pro" / "in the bridge app
            // window, then send again".
            row["hint"] = "in the bridge app window, then send again"
        }
        return row
    }

    // MARK: - Logging

    func note(_ event: String, _ fields: [String: Any] = [:]) {
        let ts = Date()
        var row: [String: Any] = ["ts": ts.timeIntervalSince1970, "event": event]
        row.merge(fields) { a, _ in a }

        let stamp = ts.formatted(date: .omitted, time: .standard)
        let detail = fields.isEmpty ? "" : "  " + fields.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
        log.append("\(stamp)  \(event)\(detail)")
        if log.count > 500 { log.removeFirst(log.count - 500) }

        guard let logURL,
              let data = try? JSONSerialization.data(withJSONObject: row),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Endpoint

    /// A headset already connected to this Mac is used without asking. Otherwise the
    /// picker decides, once per run of the app.
    private func resolveEndpoint(timeout: Duration = .seconds(3))
        async throws -> (SpatialPreviewEndpoint, String) {
        if let live = try? await connectedEndpoint(timeout: timeout) { return (live, "connected") }
        if let picked = pickedEndpoint { return (picked, "picked") }
        throw NoEndpoint()
    }

    /// `observer.endpoint` is an async getter with no documented ceiling on how long it
    /// waits. A send that produces no window and no error is the worst outcome there is,
    /// so it gets a deadline.
    private func connectedEndpoint(timeout: Duration) async throws -> SpatialPreviewEndpoint {
        let observer = self.observer
        return try await Self.withDeadline(timeout) { @MainActor in try await observer.endpoint }
    }

    func use(endpoint: SpatialPreviewEndpoint) {
        pickedEndpoint = endpoint
        showDevicePicker = false
        // Only recorded. Starting here would put the scene on the headset while
        // Blender's sidebar still says OFF - nothing tells Blender until its next send,
        // so the next send is the honest way to start.
        note("endpoint_picked", ["endpoint": "\(endpoint)"])
        problem = nil
        sessionState = "device picked - press Send in Blender"
    }

    // MARK: - Stage

    func loadStage() {
        let url = URL(fileURLWithPath: stagePath)
        problem = nil
        warning = nil
        if let previous = session {
            self.session = nil
            Task { try? await previous.close() }
            note("session_closed_for_reload")
        }
        note("stage_open_begin", ["path": url.path])

        let t0 = Date()
        do {
            let stage = try USDStage.open(url)
            // USD keeps opened layers in a process-wide registry, so opening a path we
            // have opened before hands back the copy already in memory - including
            // objects since deleted in Blender. Reload re-reads the file.
            try stage.reload()
            let openMs = Date().timeIntervalSince(t0) * 1000

            // USD calls them `points`; they are the mesh's vertices, which is the
            // word everywhere a human reads them.
            var vertices = 0
            var meshCount = 0
            for prim in stage.pseudoRoot.allDescendants {
                if let pts = prim["points", as: USDArray<USDValue.Vec3f>.self] {
                    meshCount += 1
                    vertices += pts.count
                }
            }

            warning = unresolvedUVSets(in: stage)

            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let modified = (attrs?[.modificationDate] as? Date).map {
                $0.formatted(date: .omitted, time: .standard)
            } ?? "?"

            sceneName = url.lastPathComponent
            sceneVertices = vertices
            sceneMeshes = meshCount
            sceneBytes = payloadBytes(besides: url)
            self.stage = stage

            note("stage_open_ok", [
                "open_ms": round(openMs * 100) / 100,
                "file_modified": modified,
                "file_bytes": (attrs?[.size] as? Int) ?? -1,
                "mesh_prims": meshCount,
                "total_vertices": vertices,
                "up_axis": "\(stage.upAxis)",
                "meters_per_unit": stage.metersPerUnit,
            ])
        } catch {
            note("stage_open_failed", ["error": "\(error)"])
            problem = "could not read the exported scene: \(error)"
        }
    }

    /// Every texture reader names the UV set it samples, and nothing checks that the
    /// meshes actually carry it. When they do not, the surface renders as one flat colour
    /// on the headset and looks, from Blender, exactly like a texture that failed to
    /// load. Blender's exporter can produce this from a material that renders perfectly
    /// - so verify it here rather than trusting the export.
    private func unresolvedUVSets(in stage: USDStage) -> String? {
        var available: Set<String> = []
        var wanted: [String: (count: Int, path: String)] = [:]   // UV set -> who wants it

        for prim in stage.pseudoRoot.allDescendants {
            for attribute in prim.attributes {
                let name = "\(attribute.name)"
                if name.hasPrefix("primvars:"), !name.hasSuffix(":indices") {
                    available.insert(String(name.dropFirst("primvars:".count)))
                }
            }
            if let varname = prim["inputs:varname", as: String.self] {
                let seen = wanted[varname]
                wanted[varname] = (count: (seen?.count ?? 0) + 1,
                                   path: seen?.path ?? "\(prim.path)")
            }
        }

        let missing = wanted.keys.filter { !available.contains($0) }.sorted()
        guard !missing.isEmpty else { return nil }
        let textures = missing.reduce(0) { $0 + (wanted[$1]?.count ?? 0) }
        note("uv_sets_unresolved", ["missing": missing.joined(separator: ","),
                                    "textures": textures,
                                    "available": available.sorted().joined(separator: ","),
                                    "example_shader": missing.first.flatMap { wanted[$0]?.path } ?? ""])
        return "\(textures) texture(s) sample UV set(s) the meshes do not have "
             + "(\(missing.joined(separator: ", "))) - those surfaces will arrive as flat colour"
    }

    /// The stage file plus the textures Blender wrote beside it - what ships. Not the whole
    /// folder: Apple writes a `-optimized.usdc` copy of a heavy scene next to the original,
    /// and counting it would report the scene at nearly twice its size.
    private func payloadBytes(besides url: URL) -> Int {
        let size = { (file: URL) in (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        var total = size(url)
        let textures = url.deletingLastPathComponent().appendingPathComponent("textures")
        if let walker = FileManager.default.enumerator(at: textures,
                                                       includingPropertiesForKeys: [.fileSizeKey]) {
            for case let file as URL in walker { total += size(file) }
        }
        return total
    }

    // MARK: - Session

    /// `done` fires once the session is running or has failed, never before - it is what
    /// lets Blender's reply be the outcome rather than a guess at one.
    func startSession(unmodified: Bool = false, done: (@Sendable () -> Void)?) {
        guard let stage else {
            note("start_skipped", ["reason": "no stage"])
            problem = "nothing to send - export from Blender first"
            done?()
            return
        }

        // Apple's own optimizer and compressor, both on. This is what makes heavy
        // scenes travel at all, and there is no reason to ship a way to turn it off:
        // `.unmodified` exists for isolating Apple's behaviour, not for using.
        let params = unmodified ? .unmodified : Self.optimization
        note("session_start_begin", ["parameters": "\(params)",
                                    "unmodified": unmodified])
        problem = nil
        sessionState = "starting"
        let t0 = Date()

        // Starting a second session without closing the first leaves stale scenes on
        // the headset, and the one you are looking at may not be the one you edit.
        if let previous = session {
            self.session = nil
            Task { try? await previous.close() }
            note("previous_session_closed")
        }

        let session = USDPreviewSession(stage: stage)
        let logger = ChangeLogger { [weak self] event, fields in
            self?.note(event, fields)
        }
        session.delegate = logger
        delegateBox = logger
        self.session = session

        observeEvents(of: session)
        watch(session)

        Task {
            do {
                let (endpoint, source) = try await resolveEndpoint()
                note("endpoint_resolved", ["endpoint": "\(endpoint)", "source": source])
                try await Self.withDeadline(Self.startDeadline) {
                    try await session.start(endpoint: endpoint, parameters: params)
                }
                let ms = Date().timeIntervalSince(t0) * 1000
                // A newer send may have replaced this session while it started; what the
                // window shows belongs to that one now.
                let current = self.session === session
                if current {
                    problem = nil
                    deviceLabel = "\(source) headset"
                    optimizationInUse = unmodified ? "Apple optimizer SKIPPED (diagnostic)"
                                                   : Self.optimizationLabel
                }
                note("session_start_ok", ["start_ms": round(ms), "state": "\(session.state)",
                                          "endpoint_source": source, "superseded": !current])
            } catch {
                fail(error, of: session, after: t0, unmodified: unmodified)
            }
            done?()
        }
    }

    /// A start that goes nowhere has to leave something behind: with the session gone,
    /// the window shows `sessionState` and `problem`, which say why.
    private func fail(_ error: Error, of failed: USDPreviewSession, after t0: Date,
                      unmodified: Bool = false) {
        if error is TimedOut {
            // The start may yet complete, against a session nobody is waiting for, and
            // the headset holds only three at a time.
            Task { try? await failed.close() }
        }
        // A newer send replaced this session while it was starting - typically a retry
        // after Blender gave up waiting. The newer session, and all the state the window
        // shows about it, is not this failure's to clear.
        guard session === failed else {
            note("session_start_failed", ["error": "\(error)", "superseded": true,
                                          "ms": round(Date().timeIntervalSince(t0) * 1000)])
            return
        }
        eventTask?.cancel(); eventTask = nil
        session = nil
        deviceLabel = ""

        var needsPicker = error is NoEndpoint || error is ConnectedSpatialEndpointObserver.UnavailableError
        if let sessionError = error as? SpatialPreviewSessionError,
           sessionError == .invalidSpatialPreviewEndpoint {
            needsPicker = true
            pickedEndpoint = nil
        }

        if needsPicker {
            problem = "no headset yet - pick your Vision Pro"
            sessionState = "no device"
            showDevicePicker = true
        } else if let sessionError = error as? SpatialPreviewSessionError,
                  sessionError == .tooManySessions {
            problem = "the headset has too many previews open - close them there, then send again"
            sessionState = "failed"
        } else if error is TimedOut {
            problem = "the headset never answered - close any previews on it, then send again"
            sessionState = "failed"
        } else {
            problem = "\(error)"
            sessionState = "failed"
        }
        note("session_start_failed", ["error": "\(error)",
                                      "ms": round(Date().timeIntervalSince(t0) * 1000),
                                      "needs_picker": needsPicker])
    }

    private func observeEvents(of session: USDPreviewSession) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await event in session.events {
                guard let self else { return }
                switch event {
                case .timeChanged(let t):
                    self.note("event_time_changed", ["time": t])
                case .playbackStateChanged(let playing):
                    self.note("event_playback", ["is_playing": playing])
                case .error(let e):
                    self.note("event_error", ["error": "\(e)"])
                @unknown default:
                    self.note("event_unknown")
                }
            }
        }
    }

    /// Logs each change of Apple's session state and progress as it happens - no loop,
    /// Apple calls back. The log is the record of whether closing the preview or taking
    /// the headset off ever reaches the Mac, which is what keeps the window honest.
    private func watch(_ session: USDPreviewSession) {
        withObservationTracking {
            _ = session.state
            _ = session.progress.completedCount
        } onChange: { [weak self] in
            // Fires before the change lands; read it once it has.
            Task { @MainActor in
                guard let self, self.session === session else { return }
                self.note("session_update", ["state": "\(session.state)",
                                             "completed": session.progress.completedCount])
                self.watch(session)
            }
        }
    }

    /// Quitting without this leaves the preview open on the headset, and Apple allows
    /// only a few at once - which is how repeatedly starting and quitting the app ends
    /// with sends that never arrive. Bounded, because `close` is Apple's too and its
    /// `start` has been seen never returning: a quit that hangs is worse than a preview
    /// left open.
    func closeOnQuit() async {
        guard let session else { return }
        self.session = nil
        note("closing_on_quit")
        do {
            try await Self.withDeadline(.seconds(2)) { try await session.close() }
            note("closed_on_quit")
        } catch {
            note("close_on_quit_failed", ["error": "\(error)"])
        }
    }

    func closeSession() {
        eventTask?.cancel(); eventTask = nil
        // Synchronously, so the answer Blender gets back on this same command already
        // reflects the close rather than the state it is replacing.
        problem = nil
        showDevicePicker = false
        deviceLabel = ""
        sessionState = "closed"
        guard let session else { return }
        Task {
            do { try await session.close(); note("session_closed") }
            catch { note("session_close_failed", ["error": "\(error)"]) }
        }
        self.session = nil
    }
}

/// Resumes a continuation once, for whichever of two racers gets there first.
private final class FirstResult<T: Sendable>: Sendable {
    private let resumed = OSAllocatedUnfairLock(initialState: false)
    private let continuation: CheckedContinuation<T, Error>

    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

    /// True if this call was the one that resumed it.
    @discardableResult
    func resume(_ result: Result<T, Error>) -> Bool {
        let first = resumed.withLock { done in
            defer { done = true }
            return !done
        }
        if first { continuation.resume(with: result) }
        return first
    }
}

/// Watches changes the headset sends back, including undo/redo requests. Nothing acts on
/// them yet; they are logged because they are the hook edits-from-the-headset would use.
@MainActor
final class ChangeLogger: USDPreviewSession.ChangeListDelegate {
    private let sink: (String, [String: Any]) -> Void
    init(sink: @escaping (String, [String: Any]) -> Void) { self.sink = sink }

    func willApplyChanges(instanceIdentifier: String, operationIdentifier: UInt) {
        sink("device_will_apply", ["instance": instanceIdentifier, "op": operationIdentifier])
    }
    func didApplyChanges(instanceIdentifier: String, operationIdentifier: UInt) {
        sink("device_did_apply", ["instance": instanceIdentifier, "op": operationIdentifier])
    }
    func onUndoRequest() { sink("device_undo_request", [:]) }
    func onRedoRequest() { sink("device_redo_request", [:]) }
}
