// TryonClient — the Suno Try-on HTTP seam: one multipart POST to the local
// sidecar, one image back.
//
// The sidecar proxies to the hosted gateway (stage 2), so this client speaks
// only to 127.0.0.1:8765/tryon and never sees the gateway's URL, key, or
// prompt — the same posture as AnswerClient.
//
// Wire contract (sidecar → app):
//   200  {"image": "<base64>", "mime_type": "image/png", "lease": "..."}
//   400  {"error": "...", "message": "..."}   malformed request (our bug)
//   402  bare — the account sheet's own rendering path
//   429  {"error":"limit","message":"...","retry_after":N}
//   502  {"error":"safety_block"|"unavailable","message":"..."}
//
// The person photo rides every request; the garment comes from the screen
// capture the answer turn already took.

import AppKit
import Foundation

/// Failure of one try-on generation. Mirrors AnswerClientError's taxonomy so
/// the flow's error cards read the same.
enum TryonClientError: Error {
    /// The device may not use Suno Try-on. Carries the gateway's wording and
    /// code verbatim — the account sheet renders it exactly as it renders the
    /// dictation 402.
    case notEntitled(code: String, message: String)
    /// Quota gone: try-ons/day spent, resets tomorrow.
    case limit(message: String)
    /// The model refused the images or the phrasing.
    case safetyBlock(message: String)
    /// The generation died before or during rendering (deadline, outage).
    case timeout
    /// Any other failure the user can only answer by retrying.
    case unavailable

    /// The error-card copy, mirroring AnswerClientError's wording style. The
    /// server's own messages (limit, safety) pass through where it has kinder
    /// words; ours cover only what the server leaves unsaid.
    var message: String {
        switch self {
        case .notEntitled(_, let message):
            return message
        case .limit(let message):
            return message.isEmpty
                ? "You've used all your Suno Try-ons for today. They reset tomorrow."
                : message
        case .safetyBlock(let message):
            return message.isEmpty
                ? "Suno Try-on declined this request. Try phrasing it differently."
                : message
        case .timeout:
            return "That took too long to generate. Try again."
        case .unavailable:
            return "Suno Try-on is unavailable right now. Try again shortly."
        }
    }
}

enum TryonClient {
    /// Total ceiling on one generation. The gateway's deadline is 50s; the
    /// sidecar waits 55s so its own kinder error arrives first; the app waits
    /// 90s so it never shows "timeout" while a kinder error is still in flight.
    static let deadline: TimeInterval = 90

    /// Ask for one try-on image. `garmentJPEG` is the screen capture the
    /// answer turn already took; `personJPEG` comes from PersonPhoto.
    ///
    /// Completion runs on URLSession's queue, NOT the main thread — callers
    /// hop. The task is cancellable; cancelling aborts the upload (the sidecar
    /// sees the disconnect and stops paying upstream).
    static func generate(
        item: String,
        query: String,
        personJPEG: Data,
        garmentJPEG: Data,
        context: [String: String],
        completion: @escaping (Result<NSImage, TryonClientError>) -> Void
    ) -> URLSessionDataTask {
        var urlRequest = URLRequest(url: TranscriptionClient.baseURL.appendingPathComponent("tryon"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = deadline

        // Same device-key path as /answer: per-request from the Keychain, so
        // re-pairing takes effect with no sidecar restart.
        if let deviceKey = Keychain.deviceKey() {
            urlRequest.setValue("Bearer \(deviceKey)", forHTTPHeaderField: "X-SunoFlow-Device-Key")
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append(value.data(using: .utf8) ?? Data())
            body.append("\r\n".data(using: .utf8)!)
        }
        func file(_ name: String, _ filename: String, _ data: Data) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
            body.append(data)
            body.append("\r\n".data(using: .utf8)!)
        }
        field("item", item)
        field("query", query)
        if let contextJSON: String = {
            guard let data = try? JSONSerialization.data(withJSONObject: context),
                  let str = String(data: data, encoding: .utf8) else { return nil }
            return str
        }() {
            field("context", contextJSON)
        }
        file("person", "person.jpg", personJPEG)
        file("garment", "garment.jpg", garmentJPEG)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        urlRequest.httpBody = body

        let task = URLSession.shared.dataTask(with: urlRequest) { data, response, error in
            if let error = error {
                let ns = error as NSError
                if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorTimedOut {
                    completion(.failure(.timeout))
                } else {
                    completion(.failure(.unavailable)) // cancelled or dead connection
                }
                return
            }
            guard let http = response as? HTTPURLResponse, let data = data else {
                completion(.failure(.unavailable))
                return
            }

            // A refusal comes back as the same bare 402 the dictation path
            // shows: the account sheet already knows how to render it.
            if http.statusCode == 402 {
                completion(.failure(.notEntitled(code: "not_entitled", message: "Your SunoFlow subscription isn't active.")))
                return
            }

            let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            switch http.statusCode {
            case 200:
                guard let b64 = parsed?["image"] as? String,
                      let imageData = Data(base64Encoded: b64),
                      let image = NSImage(data: imageData) else {
                    completion(.failure(.unavailable))
                    return
                }
                completion(.success(image))
            case 400:
                // Malformed request — our bug, not the user's. Read the
                // message for the log, surface as unavailable.
                completion(.failure(.unavailable))
            case 429:
                completion(.failure(.limit(message: parsed?["message"] as? String ?? "")))
            case 502:
                let code = parsed?["error"] as? String ?? "unavailable"
                let message = parsed?["message"] as? String ?? ""
                if code == "safety_block" {
                    completion(.failure(.safetyBlock(message: message)))
                } else if code == "timed out" || message == "timed out" {
                    completion(.failure(.timeout))
                } else {
                    completion(.failure(.unavailable))
                }
            default:
                completion(.failure(.unavailable))
            }
        }
        task.resume()
        return task
    }
}