import Foundation

struct TranscriptionResult: Decodable {
    let raw: String
    let cleaned: String
}

struct Correction: Decodable, Identifiable {
    let key: String
    let from: String
    let to: String
    let count: Int

    var id: String { key }
}

private struct CorrectionsResponse: Decodable {
    let corrections: [Correction]
}

private struct LearnResponse: Decodable {
    let learned: [Correction]
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

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let data = data else {
                completion(.failure(TranscriptionError.badResponse))
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

    /// Manually add a correction (from/to pair). The completion receives the
    /// updated full corrections list.
    static func addCorrection(from: String, to: String, completion: @escaping ([Correction]) -> Void) {
        post("corrections/add", fields: ["from": from, "to": to]) { data in
            completion(Self.decodeCorrections(data))
        }
    }

    /// Edit an existing correction's from/to text.
    static func updateCorrection(key: String, from: String, to: String, completion: @escaping ([Correction]) -> Void) {
        post("corrections/update", fields: ["key": key, "from": from, "to": to]) { data in
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
