import Foundation

/// One planned action from the Suno Control gateway, decoded from the flat
/// action JSON.
struct ControlAction: Decodable {
    var action: String
    var x: Int?
    var y: Int?
    var x2: Int?
    var y2: Int?
    var text: String?
    var key: String?
    var modifiers: [String]?
    var direction: String?
    var amount: Int?
    var seconds: Double?
    var note: String?
    /// On a `type` action, press Return after typing (the computer_use tool's
    /// `press_enter` — submit a field in one step). Snake_case matches the wire
    /// key, like `x2`/`y2`: the decoder maps fields by exact name.
    var press_enter: Bool?
    /// This step's token usage, when the gateway reported it — logged per step
    /// so the control log shows real per-step cost, not an estimate.
    var usage: Usage?

    /// Token accounting for one planning step (mirrors the gateway's `usage`).
    struct Usage: Decodable {
        var prompt_tokens: Int?
        var output_tokens: Int?
        var thinking_tokens: Int?
        var total_tokens: Int?
    }
}

/// Failure of one control step. `notEntitled` mirrors TranscriptionError's:
/// `not_entitled` = trial/subscription/device problem (fixed on the account
/// page); `unreachable` = we could not check. The rest stop the loop with a
/// plain message. `safetyBlock` = the AI planner declined this specific goal
/// (its safety filter) — not an outage, so the message tells the user to
/// rephrase instead of retry.
enum ControlError: Error {
    case badResponse
    case limit(message: String)
    case unavailable(message: String)
    case safetyBlock(message: String)
    case notEntitled(code: String, message: String)
    case cancelled
}

/// The wire half of Suno Control: POST one planning step to the local sidecar
/// and decode the flat action JSON. The sidecar is what proxies the hosted
/// gateway; the loop lives in ControlFlow.
enum ControlClient {
    /// One prior step of this run, as the loop reports it.
    struct Step: Encodable {
        var action: String
        var note: String
    }

    /// What the client observed this step — the planner's grounding beyond the
    /// image. Cursor coordinates are in the screenshot's pixel space, the same
    /// space the planner answers in. `os` is the full host-OS description
    /// (name, friendly name, version, build, architecture) so the planner
    /// never has to infer the platform from pixels.
    struct Context: Encodable {
        var os: String
        var app: String
        var window: String
        var cursor_x: Int?
        var cursor_y: Int?
        var image_width: Int?
        var image_height: Int?
    }

    static func plan(
        goal: String,
        steps: [Step],
        imageJPEG: Data?,
        context: Context,
        completion: @escaping (Result<ControlAction, ControlError>) -> Void
    ) {
        guard let url = URL(string: "\(TranscriptionClient.baseURL.absoluteString)/control") else {
            completion(.failure(.badResponse))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 40 // gateway 30s deadline + proxy headroom

        // Same posture as /transcribe: the device key rides every call so
        // re-pairing takes effect immediately, with no restart.
        if let deviceKey = Keychain.deviceKey() {
            request.setValue("Bearer \(deviceKey)", forHTTPHeaderField: "X-SunoFlow-Device-Key")
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append(value.data(using: .utf8) ?? Data())
            body.append("\r\n".data(using: .utf8)!)
        }
        func fileField(_ name: String, _ filename: String, _ mime: String, _ data: Data) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
            body.append(data)
            body.append("\r\n".data(using: .utf8)!)
        }

        field("goal", goal)
        field("steps", jsonString(steps))
        field("context", jsonString(context))
        if let jpeg = imageJPEG {
            fileField("image", "screen.jpg", "image/jpeg", jpeg)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { data, response, error in
            func errorEnvelope(_ data: Data?) -> (code: String, message: String)? {
                // Failure bodies arrive as JSON {"error": code, "message": ...}
                // — from the local sidecar on any status, from the gateway on
                // its 502s. Decoding them (instead of hardcoding one message)
                // is what lets a safety block say "rephrase" and a real outage
                // say "try again".
                guard let data = data,
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let code = obj["error"] as? String else { return nil }
                let message = obj["message"] as? String ?? ""
                return (code, message)
            }

            if let error = error {
                let urlError = error as? URLError
                if urlError?.code == .cancelled {
                    completion(.failure(.cancelled))
                } else {
                    completion(.failure(.unavailable(message: "Suno Control is unreachable right now.")))
                }
                return
            }
            guard let data = data else {
                completion(.failure(.badResponse))
                return
            }
            if (response as? HTTPURLResponse)?.statusCode == 402 {
                let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let message = body?["message"] as? String ?? "Your SunoFlow subscription isn't active."
                let code = body?["error"] as? String ?? "not_entitled"
                completion(.failure(.notEntitled(code: code, message: message)))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                switch errorEnvelope(data)?.code {
                case "safety_block":
                    completion(.failure(.safetyBlock(
                        message: "Suno Control's AI planner declined this goal. Try phrasing it differently.")))
                case "limit":
                    completion(.failure(.limit(
                        message: "Suno Control is working as fast as it can — wait a few seconds and try again.")))
                default:
                    completion(.failure(.unavailable(message: "Suno Control is unavailable right now.")))
                }
                return
            }
            // A 200 can still carry a failure envelope (the sidecar returns
            // {"error": ...} with HTTP 200 so the loop stops on one shape).
            if let env = errorEnvelope(data) {
                switch env.code {
                case "safety_block":
                    completion(.failure(.safetyBlock(
                        message: env.message.isEmpty
                            ? "Suno Control's AI planner declined this goal. Try phrasing it differently."
                            : env.message)))
                case "limit":
                    completion(.failure(.limit(
                        message: env.message.isEmpty
                            ? "Suno Control is working as fast as it can — wait a few seconds and try again."
                            : env.message)))
                default:
                    completion(.failure(.unavailable(
                        message: env.message.isEmpty ? "Suno Control is unavailable right now." : env.message)))
                }
                return
            }
            do {
                let action = try JSONDecoder().decode(ControlAction.self, from: data)
                completion(.success(action))
            } catch {
                completion(.failure(.badResponse))
            }
        }.resume()
    }

    /// JSON-encode via the Codable conformance, so the wire shape is defined by
    /// the structs above and nothing hand-rolled.
    private static func jsonString<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        return String(data: (try? encoder.encode(value)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
    }
}