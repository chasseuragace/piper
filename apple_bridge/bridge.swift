import Foundation
import Network
import FoundationModels

// Minimal, dependency-free OpenAI-compatible bridge over Apple's on-device
// foundation model. Exposes POST /v1/chat/completions on localhost so any
// language (here: Dart) can use the local model via plain HTTP. The model is
// prewarmed at startup and kept loaded process-wide; each request uses a fresh
// stateless session so calls don't accumulate each other's transcript.

let port: UInt16 = 8765

// Prewarm so the first real request isn't cold.
let warm = LanguageModelSession()
warm.prewarm()

func generate(system: String, prompt: String) async -> (String, Bool) {
    let model = SystemLanguageModel.default
    guard case .available = model.availability else {
        return ("on-device model unavailable", false)
    }
    do {
        let session = system.isEmpty
            ? LanguageModelSession()
            : LanguageModelSession(instructions: system)
        let response = try await session.respond(to: prompt)
        return (response.content, true)
    } catch {
        return ("\(error)", false)
    }
}

func handle(body: Data) async -> Data {
    var system = ""
    var userParts: [String] = []
    if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
       let messages = json["messages"] as? [[String: Any]] {
        for m in messages {
            let role = m["role"] as? String ?? "user"
            let content = m["content"] as? String ?? ""
            if role == "system" {
                system += content + "\n"
            } else {
                userParts.append(content)
            }
        }
    }
    let prompt = userParts.joined(separator: "\n")
    let (content, ok) = await generate(system: system, prompt: prompt)

    let payload: [String: Any]
    if ok {
        payload = [
            "model": "apple-foundation-model",
            "choices": [
                ["index": 0,
                 "message": ["role": "assistant", "content": content],
                 "finish_reason": "stop"]
            ],
        ]
    } else {
        payload = ["error": ["message": content]]
    }
    return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
}

// --- tiny HTTP/1.1 plumbing over Network.framework ---

func parseHeaders(_ buf: Data) -> (bodyStart: Int, contentLength: Int)? {
    let sep = Data("\r\n\r\n".utf8)
    guard let range = buf.range(of: sep) else { return nil }
    let headerData = buf.subdata(in: buf.startIndex..<range.lowerBound)
    let header = String(decoding: headerData, as: UTF8.self)
    var contentLength = 0
    for line in header.split(separator: "\r\n") {
        let parts = line.split(separator: ":", maxSplits: 1)
        if parts.count == 2, parts[0].lowercased().trimmingCharacters(in: .whitespaces) == "content-length" {
            contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
        }
    }
    return (range.upperBound, contentLength)
}

func sendResponse(_ conn: NWConnection, body: Data) {
    var head = "HTTP/1.1 200 OK\r\n"
    head += "Content-Type: application/json\r\n"
    head += "Content-Length: \(body.count)\r\n"
    head += "Connection: close\r\n\r\n"
    var out = Data(head.utf8)
    out.append(body)
    conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
}

func receiveRequest(_ conn: NWConnection, buffer: Data) {
    conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
        var buf = buffer
        if let d = data { buf.append(d) }
        if let (bodyStart, contentLength) = parseHeaders(buf),
           buf.count - bodyStart >= contentLength {
            let body = buf.subdata(in: bodyStart..<(bodyStart + contentLength))
            Task {
                let resp = await handle(body: body)
                sendResponse(conn, body: resp)
            }
            return
        }
        if error != nil || isComplete { conn.cancel(); return }
        receiveRequest(conn, buffer: buf)
    }
}

let listener = try! NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
listener.newConnectionHandler = { conn in
    conn.start(queue: .global())
    receiveRequest(conn, buffer: Data())
}
listener.start(queue: .global())
FileHandle.standardError.write(Data("Apple bridge listening on 127.0.0.1:\(port)\n".utf8))
dispatchMain()
