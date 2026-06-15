import FoundationModels
import Foundation

let sema = DispatchSemaphore(value: 0)

Task {
    let model = SystemLanguageModel.default
    switch model.availability {
    case .available:
        do {
            let session = LanguageModelSession()
            let r = try await session.respond(to: "Reply with exactly two words: hello world")
            print("OK: \(r.content)")
        } catch {
            print("ERR: \(error)")
        }
    case .unavailable(let reason):
        print("UNAVAILABLE: \(reason)")
    @unknown default:
        print("UNKNOWN")
    }
    sema.signal()
}

sema.wait()
