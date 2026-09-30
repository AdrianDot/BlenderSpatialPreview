import Foundation
import Network

/// Listens on loopback for commands from the Blender addon.
/// Newline-delimited JSON, one object per line, and one JSON line back per command.
/// Loopback only — both processes are on the same Mac, so there is nothing here to
/// survive a network and no need for the backpressure machinery the Quest stream carries.
final class BridgeListener {

    static let port: UInt16 = 8767

    /// The reply closure answers on the same connection the command arrived on, which is
    /// what lets Blender show the bridge's state without the Mac window being open.
    typealias Handler = @Sendable ([String: Any], @escaping @Sendable ([String: Any]) -> Void) -> Void

    /// One per connection. The buffer has to be per-peer: a reply is addressed to the
    /// connection its command came from, and a shared buffer could hand it to the wrong one.
    private final class Peer {
        let connection: NWConnection
        var buffer = Data()
        init(_ connection: NWConnection) { self.connection = connection }
    }

    private var listener: NWListener?
    private var peers: [Peer] = []
    private let onCommand: Handler
    /// Reported so a leak is visible in the log rather than only as a failure much later.
    private(set) var liveConnections = 0
    private var onStateChange: (@Sendable (String) -> Void)?

    init(onCommand: @escaping Handler, onStateChange: (@Sendable (String) -> Void)? = nil) {
        self.onCommand = onCommand
        self.onStateChange = onStateChange
    }

    func start() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback),
                                                 port: .init(rawValue: Self.port)!)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        // Without this a listener that dies - on wake from sleep, say - stays dead and
        // silent, and every send from Blender fails with no explanation on this side.
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.retryDelay = 1
            case .failed(let error):
                self?.onStateChange?("listener failed: \(error)")
                self?.restart()
            case .cancelled:
                self?.onStateChange?("listener cancelled")
            default:
                break
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    /// Seconds before the next restart, doubling to a minute. Restarting at once looped
    /// forever on the main queue when the port was held by something else - a second
    /// copy of this app, say - logging a line to disk on every pass.
    private var retryDelay: Double = 1

    private func restart() {
        listener?.cancel()
        listener = nil
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 60)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            do {
                try self.start()
                self.onStateChange?("listener restarted after \(Int(delay)) s")
            } catch {
                self.onStateChange?("listener restart failed: \(error)")
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        let peer = Peer(connection)
        peers.append(peer)
        liveConnections = peers.count
        connection.start(queue: .main)
        receive(on: peer)
    }

    /// Dropping our reference is not enough: the socket stays open until the connection
    /// is cancelled. One per message, never released, is a slow climb to the process
    /// descriptor limit - at which point new connections are reset and Blender reports
    /// the app as unreachable while it is sitting there running.
    private func release(_ peer: Peer) {
        peer.connection.cancel()
        peers.removeAll { $0 === peer }
        liveConnections = peers.count
    }

    private func receive(on peer: Peer) {
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isDone, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                peer.buffer.append(data)
                self.drainLines(of: peer)
            }
            if isDone || error != nil {
                self.release(peer)
                return
            }
            self.receive(on: peer)
        }
    }

    private func drainLines(of peer: Peer) {
        while let newline = peer.buffer.firstIndex(of: 0x0A) {
            let line = peer.buffer[peer.buffer.startIndex..<newline]
            peer.buffer = peer.buffer[peer.buffer.index(after: newline)...]
            // Anything that is not one of our commands ends the connection. Skipping it
            // let a web page in: a browser's POST to this port puts its body after header
            // lines that are not JSON, and skipping those ran the body as a command.
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            else {
                release(peer)
                return
            }

            // One command, one reply, then done: the addon opens a fresh connection per
            // message, so closing after the reply is flushed keeps every socket's life
            // bounded instead of trusting the client to hang up.
            // Only the connection is captured, never the peer or the listener: this
            // closure is @Sendable and neither of those is. Cancelling ends the receive
            // above, which is what removes the peer from the list.
            let connection = peer.connection
            onCommand(obj) { payload in
                guard var data = try? JSONSerialization.data(withJSONObject: payload) else {
                    connection.cancel()
                    return
                }
                data.append(0x0A)
                connection.send(content: data, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }
}
