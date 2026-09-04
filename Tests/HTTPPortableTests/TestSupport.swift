// Every helper here reaches the AsyncHTTPClient transport, which exists only behind the
// `HTTPPortable` trait, so the file compiles only where the transport does.
#if HTTPPortable

import AsyncHTTPClient
import Foundation
import HTTPCore
import HTTPPortable
import HTTPTypes

/// A request to `server`, on the path every fixture sends to unless told otherwise.
func target(
  of server: LoopbackServer,
  headerFields: HTTPFields = [:],
  method: HTTPRequest.Method = .get,
  path: String = "/v1/things"
) -> HTTPRequest {
  HTTPRequest(
    method: method, scheme: "http", authority: server.authority, path: path,
    headerFields: headerFields)
}

/// A transport over a client built from `configuration`, shut down once `body` has returned or
/// thrown, so no test leaves a client for AsyncHTTPClient to trap on.
func withTransport<Value>(
  configuration: AsyncHTTPClient.HTTPClient.Configuration = .init(),
  _ body: (AsyncHTTPClientTransport) async throws -> Value
) async throws -> Value {
  let transport = AsyncHTTPClientTransport(configuration: configuration)
  let outcome: Result<Value, any Error>
  do {
    outcome = .success(try await body(transport))
  } catch {
    outcome = .failure(error)
  }
  try await transport.shutdown()
  return try outcome.get()
}

/// A bare AsyncHTTPClient client, shut down once `body` has returned or thrown; a client released
/// without a shutdown takes the test process down.
func withClient<Value>(
  _ body: (AsyncHTTPClient.HTTPClient) async throws -> Value
) async throws -> Value {
  let client = AsyncHTTPClient.HTTPClient(eventLoopGroup: .singletonMultiThreadedEventLoopGroup)
  let outcome: Result<Value, any Error>
  do {
    outcome = .success(try await body(client))
  } catch {
    outcome = .failure(error)
  }
  try await client.shutdown()
  return try outcome.get()
}

/// A server running `script`, stopped once `body` has returned or thrown.
func withServer<Value>(
  _ script: Script,
  _ body: (LoopbackServer) async throws -> Value
) async throws -> Value {
  let server = try await LoopbackServer.start(script)
  let outcome: Result<Value, any Error>
  do {
    outcome = .success(try await body(server))
  } catch {
    outcome = .failure(error)
  }
  try await server.stop()
  return try outcome.get()
}

/// A server running `script` and a transport to send to it with, both torn down afterwards.
func withLoopback<Value>(
  _ script: Script,
  configuration: AsyncHTTPClient.HTTPClient.Configuration = .init(),
  _ body: (LoopbackServer, AsyncHTTPClientTransport) async throws -> Value
) async throws -> Value {
  try await withServer(script) { server in
    try await withTransport(configuration: configuration) { transport in
      try await body(server, transport)
    }
  }
}

/// The error a send failed with, or `nil` when it returned a response.
func failure(
  sending request: HTTPRequest,
  body: TransportBody = .none,
  options: TransportOptions = TransportOptions(),
  through transport: AsyncHTTPClientTransport
) async -> TransportError? {
  do {
    _ = try await transport.send(request, body: body, options: options)
    return nil
  } catch {
    return error
  }
}

/// The failure a streamed request produced before any byte was delivered, or `nil` when it produced
/// a response. A failure reported from the returned sequence is a different thing, so the body is
/// not read here.
func streamFailure(
  sending request: HTTPRequest,
  body: TransportBody = .none,
  through transport: AsyncHTTPClientTransport
) async -> TransportError? {
  do {
    _ = try await transport.stream(request, body: body, options: TransportOptions())
    return nil
  } catch {
    return error
  }
}

/// Whether the error is ``TransportError/cancelled``.
func isCancelled(_ error: TransportError) -> Bool {
  if case .cancelled = error { true } else { false }
}

/// The failure kind and wrapped error of a transport failure, or `nil` for any other case.
func transportFailure(_ error: TransportError) -> (TransportFailureKind, (any Error)?)? {
  if case .transport(let kind, let underlying) = error { (kind, underlying) } else { nil }
}

/// The body as a string.
func text(_ data: Data) -> String {
  String(decoding: data, as: UTF8.self)
}

/// The bytes of a streamed body, read to the end.
func collect(
  _ body: some AsyncSequence<Data, TransportError>
) async throws(TransportError) -> [UInt8] {
  var collected: [UInt8] = []
  for try await chunk in body { collected.append(contentsOf: chunk) }
  return collected
}

/// Every chunk of a streamed body and the failure that ended it, if one did.
func drain(_ body: StreamedBody) async -> (received: [Data], failure: TransportError?) {
  var chunks: [Data] = []
  do throws(TransportError) {
    for try await chunk in body {
      chunks.append(chunk)
    }
    return (chunks, nil)
  } catch {
    return (chunks, error)
  }
}

/// A file holding `contents`, in the temporary directory, for the transport to read from.
func temporaryFile(_ contents: Data) throws -> URL {
  let url = missingFile()
  try contents.write(to: url)
  return url
}

/// A file URL in the temporary directory that names nothing on disk.
func missingFile() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
}

// `/proc/self/fd` is a Linux kernel interface, so Android provides it too, while Darwin has nothing
// like it: the check exists on the two platforms that can answer it.
#if os(Linux) || os(Android)
/// How many of this process's file descriptors are open on `file`, read from `/proc/self/fd`, so a
/// test can see a file handle closed rather than trust that it was.
func openDescriptors(on file: URL) throws -> Int {
  let path = file.resolvingSymlinksInPath().path(percentEncoded: false)
  let directory = "/proc/self/fd"
  return try FileManager.default.contentsOfDirectory(atPath: directory)
    .filter { entry in
      (try? FileManager.default.destinationOfSymbolicLink(atPath: "\(directory)/\(entry)")) == path
    }
    .count
}
#endif

#endif
