import Foundation

struct TranscriptionResult: Decodable {
    let raw: String
    let cleaned: String
}

/// Which half of the dictionary an entry belongs to.
///
/// The two behave very differently at dictation time — a spelling is swapped in
/// mechanically, a shorthand value is only substituted where the model judges
/// the speaker was actually giving it — so the UI names the difference rather
/// than showing one undifferentiated list. See docs/CONTRACT.md §corrections.
enum CorrectionKind: String, CaseIterable, Identifiable {
    case correction
    case expansion

    var id: String { rawValue }

    var label: String {
        switch self {
        case .correction: return "Spelling"
        case .expansion:  return "Shorthand"
        }
    }

    var blurb: String {
        switch self {
        case .correction: return "A word dictation mishears, and how you write it."
        case .expansion:  return "Something you say out loud, and the value it stands for."
        }
    }

    var fromPlaceholder: String {
        switch self {
        case .correction: return "What it mishears"
        case .expansion:  return "What you say"
        }
    }

    var toPlaceholder: String {
        switch self {
        case .correction: return "What it should write"
        case .expansion:  return "The value to write instead"
        }
    }
}

struct Correction: Decodable, Identifiable {
    let key: String
    let from: String
    let to: String
    let count: Int
    /// Decoded as a plain String rather than as `CorrectionKind` on purpose: a
    /// raw value the enum does not know makes Swift throw, and a throw here
    /// empties the whole list silently. Absent altogether from a sidecar that
    /// predates the two-kind dictionary, and those only ever held spellings.
    private let kind: String?

    var id: String { key }

    var resolvedKind: CorrectionKind {
        CorrectionKind(rawValue: kind ?? "") ?? .correction
    }
}

private struct CorrectionsResponse: Decodable {
    let corrections: [Correction]
}

/// A single learned pair returned by `POST /learn`. The server does NOT send a
/// `key` field (unlike `GET /corrections`), so this is a lighter struct than
/// `Correction` — decoding `learned` into `[Correction]` fails silently and the
/// learned count always reads 0.
private struct LearnedItem: Decodable {
    let from: String
    let to: String
    let count: Int
}

private struct LearnResponse: Decodable {
    let learned: [LearnedItem]
}

/// Response shape of the cleanup gateway's unauthenticated `/ready` probe.
/// `backend_ok` is true only when the gateway's LLM backend is reachable.
private struct ReadyResponse: Decodable {
    let backend_ok: Bool
}

/// Progress/state of the STT model, reported by the sidecar's `/model/status`.
struct ModelStatus: Decodable {
    let model_present: Bool
    let model_loaded: Bool
    let active: Bool
    let phase: String        // idle | downloading | loading | done | error
    let current_file: String
    let downloaded: Int64
    let file_total: Int64
    let overall_done: Int
    let overall_total: Int
    let error: String
    let model_dir: String
    let model_id: String
}

private struct DownloadStartResponse: Decodable {
    let started: Bool
    let reason: String?
}

enum TranscriptionError: Error {
    case badResponse
    /// This Mac may not dictate. Carries the wording the gateway chose, so the
    /// app shows one consistent explanation, plus a code telling the two very
    /// different reasons apart: `not_entitled` (trial over, subscription
    /// lapsed, device disconnected — fixed on the account page) and
    /// `unreachable` (we could not check — fixed by reconnecting). Calling an
    /// outage a cancelled subscription is a support ticket waiting to happen.
    case notEntitled(code: String, message: String)
}

private func formURLEncoded(_ fields: [String: String]) -> Data {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    let body = fields.map { key, value in
        let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
        let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return "\(k)=\(v)"
    }.joined(separator: "&")
    return body.data(using: .utf8) ?? Data()
}

enum TranscriptionClient {
    static let baseURL = URL(string: "http://127.0.0.1:8765")!

    /// Base URL of the hosted cleanup gateway (transcript polishing service).
    /// The gateway owns the cleanup instruction and LLM backend; the app only
    /// probes its `/ready` for the settings connectivity status.
    static let gatewayURL = URL(string: "https://cleanup.mirrorli.art")!

    static func health(completion: @escaping (Bool) -> Void) {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 2
        URLSession.shared.dataTask(with: request) { _, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            completion(ok)
        }.resume()
    }

    static func transcribe(
        fileURL: URL,
        context: String = "",
        screenContext: String = "",
        cleanup: Bool = true,
        completion: @escaping (Result<TranscriptionResult, Error>) -> Void
    ) {
        guard var components = URLComponents(url: baseURL.appendingPathComponent("transcribe"), resolvingAgainstBaseURL: false) else {
            completion(.failure(TranscriptionError.badResponse))
            return
        }
        components.queryItems = [URLQueryItem(name: "cleanup", value: cleanup ? "true" : "false")]

        guard let url = components.url, let audioData = try? Data(contentsOf: fileURL) else {
            completion(.failure(TranscriptionError.badResponse))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30

        // The sidecar is what talks to the cleanup gateway, so this Mac's device
        // key has to travel with the request. Sending it per call rather than
        // baking it into the sidecar's environment means re-pairing takes effect
        // immediately, with no restart, and the key is never written to disk
        // outside the Keychain.
        if let deviceKey = Keychain.deviceKey() {
            request.setValue("Bearer \(deviceKey)", forHTTPHeaderField: "X-SunoFlow-Device-Key")
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"context\"\r\n\r\n".data(using: .utf8)!)
        body.append(context.data(using: .utf8) ?? Data())
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"screen\"\r\n\r\n".data(using: .utf8)!)
        body.append(screenContext.data(using: .utf8) ?? Data())
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let data = data else {
                completion(.failure(TranscriptionError.badResponse))
                return
            }
            // 402 means this Mac may not dictate. Deliberately not a soft
            // failure: nothing is pasted, and the user is told why.
            if (response as? HTTPURLResponse)?.statusCode == 402 {
                let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let message = body?["message"] as? String
                    ?? "Your SunoFlow subscription isn't active."
                let code = body?["error"] as? String ?? "not_entitled"
                completion(.failure(TranscriptionError.notEntitled(code: code, message: message)))
                return
            }
            do {
                let result = try JSONDecoder().decode(TranscriptionResult.self, from: data)
                completion(.success(result))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    // MARK: - Learning system

    private static func post(_ path: String, fields: [String: String], completion: ((Data?) -> Void)? = nil) {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formURLEncoded(fields)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            completion?(data)
        }.resume()
    }

    /// Send a (pasted, edited) pair so the sidecar can learn corrections.
    static func learn(original: String, edited: String, completion: @escaping (Int) -> Void) {
        post("learn", fields: ["original": original, "edited": edited]) { data in
            guard let data = data,
                  let resp = try? JSONDecoder().decode(LearnResponse.self, from: data) else {
                completion(0)
                return
            }
            completion(resp.learned.count)
        }
    }

    static func fetchCorrections(completion: @escaping ([Correction]) -> Void) {
        var request = URLRequest(url: baseURL.appendingPathComponent("corrections"))
        request.timeoutInterval = 3
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data = data,
                  let resp = try? JSONDecoder().decode(CorrectionsResponse.self, from: data) else {
                completion([])
                return
            }
            completion(resp.corrections)
        }.resume()
    }

    static func deleteCorrection(key: String, completion: @escaping () -> Void) {
        post("corrections/delete", fields: ["key": key]) { _ in completion() }
    }

    static func clearCorrections(completion: @escaping () -> Void) {
        post("corrections/clear", fields: [:]) { _ in completion() }
    }

    /// Manually add an entry (from/to pair). The completion receives the updated
    /// full corrections list. The wire field is `frm` (not `from`) because
    /// `from` is a Python keyword and the FastAPI endpoint names the parameter
    /// `frm` — sending `from` gets a silent 422.
    ///
    /// A nil `kind` sends no `kind` field, leaving the sidecar to infer it from
    /// the shape of the pair. That is the default: the classifier lives in one
    /// place rather than being second-guessed here, and the list refreshes
    /// straight after with the badge showing what it decided.
    static func addCorrection(from: String, to: String, kind: CorrectionKind? = nil,
                              completion: @escaping ([Correction]) -> Void) {
        var fields = ["frm": from, "to": to]
        if let kind { fields["kind"] = kind.rawValue }
        post("corrections/add", fields: fields) { data in
            completion(Self.decodeCorrections(data))
        }
    }

    /// Edit an existing entry's from/to text. Wire field is `frm` (see above).
    /// The kind is always sent here: an edit should not silently reclassify an
    /// entry the user already placed.
    static func updateCorrection(key: String, from: String, to: String, kind: CorrectionKind? = nil,
                                 completion: @escaping ([Correction]) -> Void) {
        var fields = ["key": key, "frm": from, "to": to]
        if let kind { fields["kind"] = kind.rawValue }
        post("corrections/update", fields: fields) { data in
            completion(Self.decodeCorrections(data))
        }
    }

    private static func decodeCorrections(_ data: Data?) -> [Correction] {
        guard let data = data,
              let resp = try? JSONDecoder().decode(CorrectionsResponse.self, from: data) else {
            return []
        }
        return resp.corrections
    }

    // MARK: - Hosted cleanup gateway

    /// Reachability of the hosted cleanup service. Replaces the old local-Ollama
    /// probe — cleanup no longer runs on the user's machine. The gateway's
    /// `/ready` is unauthenticated and reports whether its LLM backend is up.
    static func checkCleanupGateway(completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: gatewayURL.appendingPathComponent("ready").absoluteString) else {
            completion(false)
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        URLSession.shared.dataTask(with: request) { data, _, _ in
            // `/ready` returns {"backend_ok": true|false}. Treat any 200 with a
            // truthy backend_ok as reachable; fall back to false otherwise so the
            // UI shows "offline" rather than a misleading green dot.
            let ok = data
                .flatMap { try? JSONDecoder().decode(ReadyResponse.self, from: $0) }
                .map { $0.backend_ok } ?? false
            completion(ok)
        }.resume()
    }

    // MARK: - STT model download

    /// Current state of the Parakeet model (present on disk, loaded, download progress).
    static func fetchModelStatus(completion: @escaping (ModelStatus?) -> Void) {
        var request = URLRequest(url: baseURL.appendingPathComponent("model/status"))
        request.timeoutInterval = 4
        URLSession.shared.dataTask(with: request) { data, _, _ in
            let status = data.flatMap { try? JSONDecoder().decode(ModelStatus.self, from: $0) }
            completion(status)
        }.resume()
    }

    /// Kick off the background model download. Returns whether it actually
    /// started (false if one is already running or the model is already present).
    static func startModelDownload(completion: @escaping (Bool) -> Void) {
        var request = URLRequest(url: baseURL.appendingPathComponent("model/download"))
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { data, _, _ in
            let started = data
                .flatMap { try? JSONDecoder().decode(DownloadStartResponse.self, from: $0) }
                .map { $0.started } ?? false
            completion(started)
        }.resume()
    }
}
