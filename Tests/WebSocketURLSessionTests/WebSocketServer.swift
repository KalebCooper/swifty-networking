#if canImport(Darwin)
import CryptoKit
import Foundation
import Network
import Security
import Synchronization
import WebSocketCore

/// A loopback wire fixture with independently specified HTTP responses and frame bytes.
final class WebSocketServer: Sendable {
  struct Frame: Sendable {
    let opcode: UInt8
    let payload: [UInt8]
  }

  final class Peer: Sendable {
    private struct State {
      var cancelled = false
      var pending: [UUID: @Sendable () -> Void] = [:]
    }

    let connection: NWConnection
    private let state = Mutex(State())

    init(connection: NWConnection) { self.connection = connection }

    func cancel() {
      let callbacks = state.withLock { state in
        state.cancelled = true
        let callbacks = Array(state.pending.values)
        state.pending.removeAll()
        return callbacks
      }
      connection.cancel()
      for callback in callbacks { callback() }
    }

    func frame() async throws -> Frame {
      let head = try await read(2)
      let length = head[1] & 127
      let count: Int
      if length == 126 {
        let bytes = try await read(2)
        count = Int(bytes[0]) * 256 + Int(bytes[1])
      } else {
        guard length < 126 else { throw WebSocketError(kind: .protocolViolation) }
        count = Int(length)
      }
      let mask = head[1] & 128 == 0 ? [] : try await read(4)
      var body = try await read(count)
      if !mask.isEmpty {
        for i in body.indices { body[i] ^= mask[i % 4] }
      }
      return Frame(opcode: head[0] & 15, payload: body)
    }

    func read(_ count: Int) async throws -> [UInt8] {
      if count == 0 { return [] }
      let result = WebSocketCompletion<Data>()
      let id = UUID()
      let accepted = state.withLock { state in
        guard !state.cancelled else { return false }
        state.pending[id] = { result.finish(.failure(WebSocketError(kind: .cancelled))) }
        return true
      }
      guard accepted else { throw WebSocketError(kind: .cancelled) }
      defer { state.withLock { _ = $0.pending.removeValue(forKey: id) } }
      connection.receive(minimumIncompleteLength: count, maximumLength: count) {
        data, _, _, error in
        if let data, data.count == count {
          result.finish(.success(data))
        } else {
          result.finish(.failure(WebSocketError(kind: .transport, underlying: error)))
        }
      }
      return Array(try await result.wait())
    }

    func request() async throws -> String {
      var bytes: [UInt8] = []
      while !bytes.suffix(4).elementsEqual([13, 10, 13, 10]) {
        guard bytes.count < 16_384 else { throw WebSocketError(kind: .invalidRequest) }
        bytes += try await read(1)
      }
      return String(decoding: bytes, as: UTF8.self)
    }

    func send(_ bytes: [UInt8]) async throws {
      let result = WebSocketCompletion<Void>()
      let id = UUID()
      let accepted = state.withLock { state in
        guard !state.cancelled else { return false }
        state.pending[id] = { result.finish(.failure(WebSocketError(kind: .cancelled))) }
        return true
      }
      guard accepted else { throw WebSocketError(kind: .cancelled) }
      defer { state.withLock { _ = $0.pending.removeValue(forKey: id) } }
      connection.send(
        content: Data(bytes),
        completion: .contentProcessed { error in
          result.finish(
            error.map { .failure(WebSocketError(kind: .transport, underlying: $0)) } ?? .success(())
          )
        })
      try await result.wait()
    }

    func upgrade(_ request: String, extra: String = "", frames: [UInt8] = []) async throws {
      let key =
        request.components(separatedBy: "\r\n").first {
          $0.lowercased().hasPrefix("sec-websocket-key:")
        }?.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? ""
      let digest = Insecure.SHA1.hash(
        data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
      let accept = Data(digest).base64EncodedString()
      let response =
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\(extra)\r\n"
      try await send(Array(response.utf8) + frames)
    }
  }

  private struct State {
    var peers: [UUID: Peer] = [:]
    var stopped = false
  }

  private let handler: @Sendable (Peer, String) async throws -> Void
  private let listener: NWListener
  private let secure: Bool
  let accepted = WebSocketCompletion<Void>()
  let ready = WebSocketCompletion<UInt16>()
  let requests = Mutex<[String]>([])
  private let state = Mutex(State())

  init(
    identity: SecIdentity? = nil,
    handler: @escaping @Sendable (Peer, String) async throws -> Void
  ) throws {
    self.handler = handler
    secure = identity != nil
    let parameters: NWParameters
    if let identity {
      guard let networkIdentity = sec_identity_create(identity) else {
        throw WebSocketError(kind: .transport)
      }
      let tls = NWProtocolTLS.Options()
      sec_protocol_options_set_local_identity(tls.securityProtocolOptions, networkIdentity)
      parameters = NWParameters(tls: tls, tcp: .init())
    } else {
      parameters = .tcp
    }
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    listener = try NWListener(using: parameters)
    listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
    listener.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      switch state {
      case .ready:
        if let port = self.listener.port { self.ready.finish(.success(port.rawValue)) }
      case .failed(let error):
        self.ready.finish(.failure(WebSocketError(kind: .transport, underlying: error)))
      case .cancelled: self.ready.finish(.failure(WebSocketError(kind: .cancelled)))
      default: break
      }
    }
    listener.start(queue: DispatchQueue(label: "WebSocketServer"))
  }

  private func accept(_ connection: NWConnection) {
    let id = UUID()
    let peer = Peer(connection: connection)
    let accepted = state.withLock { state in
      guard !state.stopped else { return false }
      state.peers[id] = peer
      return true
    }
    guard accepted else { connection.cancel(); return }
    self.accepted.finish(.success(()))
    connection.start(queue: DispatchQueue(label: "WebSocketPeer"))
    Task {
      defer {
        peer.cancel()
        state.withLock { _ = $0.peers.removeValue(forKey: id) }
      }
      do {
        let request = try await peer.request()
        requests.withLock { $0.append(request) }
        try await handler(peer, request)
      } catch {}
    }
  }

  func stop() {
    let peers = state.withLock { state in
      state.stopped = true
      return Array(state.peers.values)
    }
    listener.cancel()
    for peer in peers { peer.cancel() }
  }

  func url(_ path: String = "/", host: String = "127.0.0.1") async throws -> URL {
    let port = try await ready.wait()
    let scheme = secure ? "wss" : "ws"
    guard let url = URL(string: "\(scheme)://\(host):\(port)\(path)") else {
      throw WebSocketError(kind: .invalidRequest)
    }
    return url
  }
}
#endif
