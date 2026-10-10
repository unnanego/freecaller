import Foundation

struct PBError: Error, CustomStringConvertible {
  let status: Int
  let message: String

  var description: String { "PocketBase \(status): \(message)" }
}

/// A call record, as much of it as the watch needs.
struct CallRecord: Decodable {
  let id: String
  let callerId: String
  let calleeId: String
  let callerName: String
  let state: String
  let endedBy: String
  let answeredOn: String

  enum CodingKeys: String, CodingKey {
    case id, callerId, calleeId, callerName, state, endedBy, answeredOn
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    callerId = (try? c.decode(String.self, forKey: .callerId)) ?? ""
    calleeId = (try? c.decode(String.self, forKey: .calleeId)) ?? ""
    callerName = (try? c.decode(String.self, forKey: .callerName)) ?? ""
    state = (try? c.decode(String.self, forKey: .state)) ?? ""
    endedBy = (try? c.decode(String.self, forKey: .endedBy)) ?? ""
    answeredOn = (try? c.decode(String.self, forKey: .answeredOn)) ?? ""
  }

  var isTerminal: Bool { ["declined", "cancelled", "missed", "ended"].contains(state) }
}

/// The handful of PocketBase requests the watch makes. Plain HTTPS: watchOS
/// allows URLSession HTTP at any time (only sockets are restricted to an active
/// call), so signaling never depends on the bridge.
///
/// Mirrors lib/data/call_repo.dart and lib/data/device_repo.dart; the server
/// (deploy/pocketbase/pb_hooks/calls.pb.js) is the authority on every rule.
final class PocketBase {
  static let shared = PocketBase()

  private let session: URLSession = {
    let cfg = URLSessionConfiguration.default
    cfg.timeoutIntervalForRequest = 10
    cfg.waitsForConnectivity = false
    return URLSession(configuration: cfg)
  }()

  // MARK: - calls

  func getCall(_ callId: String, token: String) async throws -> CallRecord {
    try await request("GET", "/api/collections/calls/records/\(callId)", token: token)
  }

  /// Create a ringing call. The server overwrites the caller's name, number,
  /// expiry and state from its own data; callerId and state are still sent
  /// because the create rule checks them.
  func createCall(callId: String, callerId: String, calleeId: String, token: String) async throws {
    let _: CallRecord = try await request(
      "POST", "/api/collections/calls/records", token: token,
      body: [
        "id": callId,
        "callerId": callerId,
        "calleeId": calleeId,
        "isVideo": false,
        "state": "ringing",
      ])
  }

  /// Move a call to [state], stamping the matching time field the way
  /// CallRepo.setState does.
  func setState(
    _ callId: String, _ state: String, token: String,
    endedBy: String? = nil, answeredOn: String? = nil
  ) async throws {
    let now = ISO8601DateFormatter().string(from: Date())
    var body: [String: Any] = ["state": state]
    if state == "accepted" { body["acceptedAt"] = now }
    if ["ended", "declined", "cancelled", "missed"].contains(state) { body["endedAt"] = now }
    if let endedBy { body["endedBy"] = endedBy }
    if let answeredOn { body["answeredOn"] = answeredOn }
    let _: CallRecord = try await request(
      "PATCH", "/api/collections/calls/records/\(callId)", token: token, body: body)
  }

  // MARK: - devices

  /// Register this watch's VoIP token. Find-then-write, as DeviceRepo.upsert;
  /// pb_hooks/devices.pb.js hands the install over if it was last registered
  /// to another account.
  func upsertDevice(userId: String, deviceId: String, voipToken: String, token: String) async throws {
    let body: [String: Any] = [
      "user": userId,
      "deviceId": deviceId,
      "platform": "watchos",
      "voipToken": voipToken,
    ]
    if let existing = try await findDevice(userId: userId, deviceId: deviceId, token: token) {
      let _: IdOnly = try await request(
        "PATCH", "/api/collections/devices/records/\(existing)", token: token, body: body)
    } else {
      let _: IdOnly = try await request(
        "POST", "/api/collections/devices/records", token: token, body: body)
    }
  }

  func deleteDevice(userId: String, deviceId: String, token: String) async throws {
    guard let existing = try await findDevice(userId: userId, deviceId: deviceId, token: token)
    else { return }
    try await requestNoContent("DELETE", "/api/collections/devices/records/\(existing)", token: token)
  }

  private func findDevice(userId: String, deviceId: String, token: String) async throws -> String? {
    // Both values are ours (server-issued uid, our own UUID), never user input.
    let filter = "user = '\(userId)' && deviceId = '\(deviceId)'"
    let page: Page<IdOnly> = try await request(
      "GET", "/api/collections/devices/records", token: token,
      query: ["filter": filter, "perPage": "1"])
    return page.items.first?.id
  }

  // MARK: - account

  /// Re-issue the token, pushing its expiry out. Returns the new token.
  func authRefresh(token: String) async throws -> String {
    let out: AuthResponse = try await request(
      "POST", "/api/collections/users/auth-refresh", token: token, body: [:])
    return out.token
  }

  /// The admin-managed roster (`contacts` relation), as contacts.
  func fetchRoster(userId: String, token: String) async throws -> [Contact] {
    let me: RosterOwner = try await request(
      "GET", "/api/collections/users/records/\(userId)", token: token,
      query: ["expand": "contacts", "fields": "id,expand.contacts.id,expand.contacts.displayName,expand.contacts.phone"])
    return (me.expand?.contacts ?? []).map {
      Contact(uid: $0.id, displayName: $0.displayName ?? "", phone: $0.phone ?? "")
    }
  }

  // MARK: - plumbing

  private struct IdOnly: Decodable { let id: String }
  private struct Page<T: Decodable>: Decodable { let items: [T] }
  private struct AuthResponse: Decodable { let token: String }
  private struct RosterOwner: Decodable {
    struct Expand: Decodable { let contacts: [Person]? }
    struct Person: Decodable {
      let id: String
      let displayName: String?
      let phone: String?
    }
    let expand: Expand?
  }

  /// One batch of the watch's log, into the same write-only `diagnostics`
  /// collection the Android app reports audio routes to (read with
  /// tools/diagnostics.mjs). Only a superuser can read it back.
  func postDiagnostics(userId: String, callId: String, detail: String, token: String) async throws {
    _ = try await send(
      makeRequest(
        "POST", "/api/collections/diagnostics/records", token: token, query: [:],
        body: [
          "userUid": userId, "callId": callId, "platform": "watchos", "event": "watch-log",
          "detail": detail,
        ]))
  }

  private func makeRequest(
    _ method: String, _ path: String, token: String,
    query: [String: String], body: [String: Any]?
  ) throws -> URLRequest {
    var comps = URLComponents(string: Config.pbURL.absoluteString + path)!
    if !query.isEmpty {
      comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
    }
    var req = URLRequest(url: comps.url!)
    req.httpMethod = method
    req.setValue(token, forHTTPHeaderField: "Authorization")
    if let body {
      req.httpBody = try JSONSerialization.data(withJSONObject: body)
      req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    return req
  }

  private func send(_ req: URLRequest) async throws -> Data {
    let (data, response) = try await session.data(for: req)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
      let message =
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["message"] as? String ?? ""
      throw PBError(status: status, message: message)
    }
    return data
  }

  private func request<T: Decodable>(
    _ method: String, _ path: String, token: String,
    query: [String: String] = [:], body: [String: Any]? = nil
  ) async throws -> T {
    let data = try await send(makeRequest(method, path, token: token, query: query, body: body))
    return try JSONDecoder().decode(T.self, from: data)
  }

  private func requestNoContent(_ method: String, _ path: String, token: String) async throws {
    _ = try await send(makeRequest(method, path, token: token, query: [:], body: nil))
  }
}
