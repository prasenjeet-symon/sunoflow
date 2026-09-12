// AnswerClient — the Suno Answer HTTP seam: one multipart POST to the local
// sidecar, one SSE stream back.
//
// The sidecar proxies to the hosted gateway (stage 2), so this client speaks
// only to 127.0.0.1:8765/answer and never sees the gateway's URL, key, or
// prompt — the same posture as TranscriptionClient.
//
// Wire contract (sidecar → app, byte-for-byte from the gateway):
//   meta    {"lease": "..."}           first event, always
//   tryon   {"item": "..."}            a try-on request surfaced by the answer
//   delta   {"text": "..."}            one fragment of the answer
//   sources {"domains":[...],"queries":N}
//   done    {}
//   error   {"error":code,"message":"..."}  terminal — no fallback after it
//
// Pre-stream failures ride the same shape: the sidecar translates refusals to
// a bare 402 (the account sheet's own rendering path) and everything else to a
// single in-stream `error` event, so the caller parses one response body.

import Foundation

/// Failure of one answer turn. Named AnswerClientError (not AnswerError) so it
/// never shadows AnswerFlow's card-copy enum of the same name.
enum AnswerClientError: Error {
    /// The device may not use Suno Answer. Carries the gateway's wording and
    /// code verbatim — the account sheet renders it exactly as it renders the
    /// dictation 402.
    case notEntitled(code: String, message: String)
    /// Quota gone: messages/day spent, resets tomorrow.
    case limit
    /// The stream died before or during generation (deadline, outage).
    case timeout
    /// Any other failure the user can only answer by retrying.
    case unavailable
    /// The model could not answer the question.
    case unable

    /// The error-card copy, mirroring D4's taxonomy.
    var message: String {
        switch self {
        case .notEntitled(_, let message):
            return message
        case .limit:
            return "You've used all your Suno Answers for today. They reset tomorrow."
        case .timeout:
            return "That took too long to answer. Try again."
        case .unavailable:
            return "Suno Answer is unavailable right now. Try again shortly."
        case .unable:
            return "Suno couldn't answer that one. Try rephrasing."
        }
    }
}

enum AnswerClient {
    /// Total ceiling on one answer turn. The gateway's deadline is 90s; the
    /// sidecar waits 100s so its own kinder timeout event arrives; the app
    /// waits 110s so it never shows "timeout" while a kinder error is still
    /// in flight.
    static let deadline: TimeInterval = 110

    /// One turn of an answer session. `image` rides the FIRST turn only.
    struct Request {
        var query: String
        var history: [(q: String, a: String)]
        var imageJPEG: Data?
        /// True when a person photo is on file: the sidecar forwards the flag
        /// so the gateway may emit a tryon event at all. Absent ⇒ "false".
        var tryonAvailable: Bool
    }

    /// Events an answer stream yields, in order.
    enum Event {
        case meta
        /// The sidecar corrected the dictated query against the user's
        /// dictionary before forwarding it. Carries the corrected wording —
        /// arrives before any delta, turn 1 or follow-up.
        case query(String)
        /// The answer's text asked to try the named item on the user — the
        /// gateway holds the marker back from the deltas and sends it as its
        /// own event. The flow runs the generation and shows the image.
        case tryon(item: String)
        case delta(String)
        case sources(domains: [String], queries: Int)
        case done
        /// Terminal failure. Internal to the parser: the caller sees it as a
        /// failed completion, never as a live event.
        case error(code: String, message: String)
    }

    /// POST one answer turn and stream the response as parsed events.
    ///
    /// `onEvent` runs on URLSession's delegate queue, NOT the main thread —
    /// callers hop. Terminal: onEvent(.done) then completion(.success), or
    /// completion(.failure) with no done. The task is cancellable; cancelling
    /// aborts the upload mid-stream (the sidecar sees the disconnect and stops
    /// paying upstream).
    static func stream(
        _ request: Request,
        onEvent: @escaping (Event) -> Void,
        completion: @escaping (Result<Void, AnswerClientError>) -> Void
    ) -> URLSessionDataTask {
        var urlRequest = URLRequest(url: TranscriptionClient.baseURL.appendingPathComponent("answer"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = deadline

        // Same device-key path as /transcribe: per-request from the Keychain,
        // so re-pairing takes effect with no sidecar restart.
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
        field("query", request.query)
        if request.tryonAvailable {
            field("tryon", "true")
        }
        let historyJSON: String = {
            // JSONSerialization, not hand-rolled escaping — a dictated quote
            // inside a question must not break the array.
            let objs: [[String: String]] = request.history.map { ["q": $0.q, "a": $0.a] }
            guard let data = try? JSONSerialization.data(withJSONObject: objs),
                  let str = String(data: data, encoding: .utf8) else { return "[]" }
            return str
        }()
        field("history", historyJSON)
        if let image = request.imageJPEG {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"image\"; filename=\"screen.jpg\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
            body.append(image)
            body.append("\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        urlRequest.httpBody = body

        let task = URLSession.shared.dataTask(with: urlRequest) { data, response, error in
            // dataTask buffers the whole body; SSE arrives as one blob at the
            // end. Fine for answers (bounded by the deadline, text-sized) and
            // it keeps the parse in one place.
            if let error = error {
                completion(.failure(map(error)))
                return
            }
            guard let http = response as? HTTPURLResponse, let data = data else {
                completion(.failure(.unavailable))
                return
            }

            // A refusal comes back as the same 402 the dictation path shows:
            // the account sheet already knows how to render it.
            if http.statusCode == 402 {
                let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                completion(.failure(.notEntitled(
                    code: parsed?["error"] as? String ?? "not_entitled",
                    message: parsed?["message"] as? String ?? "Your SunoFlow subscription isn't active."
                )))
                return
            }

            guard http.statusCode == 200 else {
                completion(.failure(.unavailable))
                return
            }

            var outcome: Result<Void, AnswerClientError> = .success(())
            var sawDone = false
            var sawError = false
            for event in parseSSE(data) {
                switch event {
                case .query, .delta, .sources, .meta, .tryon:
                    onEvent(event)
                case .done:
                    sawDone = true
                    onEvent(.done)
                case .error(let code, let message):
                    sawError = true
                    outcome = .failure(map(code: code, message: message))
                }
            }
            if !sawError, !sawDone {
                // A stream that ends without done and without error is a
                // broken stream, not a complete answer. An error event already
                // decided the outcome; leave it be.
                outcome = .failure(.unavailable)
            }
            completion(outcome)
        }
        task.resume()
        return task
    }

    // MARK: - SSE parsing

    private struct SSEEvent {
        let name: String
        let data: String
    }

    private static func parseSSE(_ data: Data) -> [Event] {
        guard let text = String(data: data, encoding: .utf8) else { return [.error(code: "unavailable", message: "unreadable stream")] }
        var events: [Event] = []
        var name = ""
        var payload = ""
        func flush() {
            guard !name.isEmpty else { return }
            defer { name = ""; payload = "" }
            switch name {
            case "meta":
                events.append(.meta)
            case "query":
                if let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                   let text = obj["query"] as? String, !text.isEmpty {
                    events.append(.query(text))
                }
            case "tryon":
                if let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                   let item = obj["item"] as? String, !item.isEmpty {
                    events.append(.tryon(item: item))
                }
            case "delta":
                if let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                   let text = obj["text"] as? String, !text.isEmpty {
                    events.append(.delta(text))
                }
            case "sources":
                if let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] {
                    let domains = obj["domains"] as? [String] ?? []
                    let queries = obj["queries"] as? Int ?? 0
                    events.append(.sources(domains: domains, queries: queries))
                }
            case "done":
                events.append(.done)
            case "error":
                if let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] {
                    events.append(.error(code: obj["error"] as? String ?? "unavailable",
                                         message: obj["message"] as? String ?? ""))
                } else {
                    events.append(.error(code: "unavailable", message: ""))
                }
            default:
                break
            }
        }
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("event: ") {
                name = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data: ") {
                payload = String(line.dropFirst(6))
            } else if line.isEmpty {
                flush()
            }
        }
        flush() // tolerate a missing final blank line
        return events
    }

    private static func map(code: String, message: String) -> AnswerClientError {
        switch code {
        case "limit":
            return .limit
        case "timeout":
            return .timeout
        case "unable":
            return .unable
        case "unavailable":
            return .unavailable
        default:
            // Unknown code from a newer gateway: degrade to unavailable, but
            // keep the message if the gateway sent one.
            return message.isEmpty ? .unavailable : .unable
        }
    }

    private static func map(_ error: Error) -> AnswerClientError {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorTimedOut:
                return .timeout
            case NSURLErrorCancelled:
                return .unavailable // dismissed by the user; the flow ignores it
            default:
                return .unavailable
            }
        }
        return .unavailable
    }
}

extension AnswerClient.Event: Equatable {}