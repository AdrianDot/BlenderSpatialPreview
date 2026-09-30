import AppKit
import SwiftUI
import SpatialPreview

@main
struct BridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    /// One for the life of the app, never one per window: the model owns the listener and
    /// the session. A window opened later - from the Dock after closing this one, or with
    /// New Window - made a second model, which could not bind the port and orphaned any
    /// preview the first one had open on the headset.
    @State private var model = BridgeModel()

    var body: some Scene {
        // A WindowGroup, not a Window: with a Window as its only scene the app quits when
        // it is closed, and the app is meant to keep running with its window closed.
        WindowGroup("Spatial Preview Bridge") {
            BridgeView(model: model)
        }
        // The window is exactly its content: about two business cards, growing only
        // while the log is open or a problem is shown. It is a status readout, not a
        // workspace.
        .windowResizability(.contentSize)
    }
}

/// Quitting has to take the preview off the headset with it: an abandoned session still
/// counts against the few Apple allows, and the next send then goes nowhere.
/// Termination is held open rather than the main thread blocked: the close runs on the
/// main actor, so blocking it while waiting for the close meant the close never started.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = BridgeModel.shared else { return .terminateNow }
        Task { @MainActor in
            await model.closeOnQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// A window with nothing to press. Blender drives the whole pipeline over the socket;
/// this reports what the Mac half did with it, and offers the device picker for the one
/// case Apple makes us ask about.
struct BridgeView: View {
    @Bindable var model: BridgeModel
    /// Hidden by default: the cards say what happened, the log is for finding out why.
    @AppStorage("showLog") private var showLog = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            VStack(spacing: 10) {
                if let problem = model.problem { banner(problem) }
                scene
                session
            }
            .padding(12)

            Divider()
            logToggle
            if showLog { logPane }
            Divider()
            credits
        }
        .frame(width: 340)
        .sheet(isPresented: $model.showDevicePicker) {
            SpatialPreviewDevicePicker(isPresented: $model.showDevicePicker) { endpoint in
                model.use(endpoint: endpoint)
            }
        }
        // The picker can be raised by a send from Blender, with this window behind
        // everything else. Unfocused, it would look exactly like nothing happening.
        .onChange(of: model.showDevicePicker) { _, showing in
            if showing { NSApp.activate() }
        }
    }

    /// The one thing worth interrupting the layout for: a send that did not arrive.
    private func banner(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text).font(.callout)
            Spacer()
            // Only when picking is the answer. "could not read the exported scene" with a
            // Pick device button next to it sends people the wrong way.
            if model.sessionState == "no device" {
                Button("Pick device…") { model.showDevicePicker = true }
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.orange.opacity(0.35)))
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "visionpro")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Spatial Preview Bridge")
                    .font(.system(size: 13, weight: .semibold))
                Text("Blender  →  Vision Pro")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            statusPill
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var statusPill: some View {
        let connected = model.isSessionRunning
        let ready = model.endpointAvailable
        let (color, label): (Color, String) =
            connected ? (.green, "showing")
            : ready ? (.orange, "headset ready")
            : (.secondary, "no headset")
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.3)))
    }

    // MARK: - Scene

    private var scene: some View {
        Card("Scene") {
            if model.sceneVertices == 0 {
                HStack(spacing: 8) {
                    Text("Nothing loaded — press **Send to Vision Pro** in Blender.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.sceneName).font(.system(.body, weight: .medium))
                    HStack(spacing: 18) {
                        Stat("vertices", model.sceneVertices.formatted())
                        Stat("objects", model.sceneMeshes.formatted())
                        Stat("payload", byteLabel(model.sceneBytes))
                    }
                }
            }
        }
    }

    // MARK: - Session

    private var session: some View {
        Card("Session") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(model.sessionLine)
                        .font(.system(.callout, design: .monospaced))
                    Spacer()
                    Text(model.progressLine)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Image(systemName: model.deviceLabel.isEmpty ? "circle.dotted" : "visionpro")
                        .foregroundStyle(.secondary)
                    Text(model.deviceLabel.isEmpty ? "no device" : model.deviceLabel)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("port 8767").font(.caption).foregroundStyle(.tertiary)
                }
                HStack(spacing: 6) {
                    Image(systemName: "archivebox")
                        .foregroundStyle(.secondary)
                    Text(model.optimizationInUse)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }

    // MARK: - Log

    private var logToggle: some View {
        Button {
            showLog.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: showLog ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                Text("Log").font(.caption.weight(.medium))
                Spacer()
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var logPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.log.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(10)
            }
            .frame(height: 140)
            .background(.background.secondary)
            .onChange(of: model.log.count) { _, count in
                proxy.scrollTo(count - 1, anchor: .bottom)
            }
            // Opened after a send, it should show that send, not the first line.
            .onAppear { proxy.scrollTo(model.log.count - 1, anchor: .bottom) }
        }
    }

    // MARK: - Credits

    private var credits: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("Find more on X:")
                Link("@Adrian_Schr", destination: URL(string: "https://x.com/Adrian_Schr")!)
            }
            HStack(spacing: 4) {
                Text("Source code on GitHub:")
                Link("AdrianDot/BlenderSpatialPreview",
                     destination: URL(string: "https://github.com/AdrianDot/BlenderSpatialPreview")!)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func byteLabel(_ bytes: Int) -> String {
        bytes >= 1_000_000 ? String(format: "%.1f MB", Double(bytes) / 1e6)
                           : String(format: "%.0f KB", Double(bytes) / 1e3)
    }
}

// MARK: - Small pieces

private struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.8)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }
}

private struct Stat: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(.body, design: .rounded).weight(.medium).monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
