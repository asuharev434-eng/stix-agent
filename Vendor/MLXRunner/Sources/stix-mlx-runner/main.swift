import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXVLM
import Tokenizers

private struct Request: Decodable {
    struct Message: Decodable {
        let role: String
        let content: String
        let imageURLs: [String]?
    }
    let directory: String
    let vision: Bool
    let messages: [Message]
    let maxTokens: Int
}

private struct Event: Encodable {
    let type: String
    let text: String?
    let name: String?
    let arguments: String?
    let id: String?
}

private func emit(_ event: Event) {
    guard let data = try? JSONEncoder().encode(event) else { return }
    FileHandle.standardOutput.write(Data("STIX_EVENT:".utf8) + data + Data([10]))
}

@main
struct Runner {
    static func main() async {
        do { try await run() }
        catch {
            emit(Event(type: "error", text: error.localizedDescription, name: nil, arguments: nil, id: nil))
            exit(1)
        }
    }

    private static func run() async throws {
        guard CommandLine.arguments.count == 2 else { throw RunnerError.invalidArguments }
        let request = try JSONDecoder().decode(Request.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        guard request.directory.hasPrefix("/"), (1...32768).contains(request.maxTokens),
              !request.messages.isEmpty, request.messages.count <= 512 else { throw RunnerError.invalidArguments }
        let directory = URL(fileURLWithPath: request.directory)
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.json").path) else {
            throw RunnerError.missingModel
        }
        let tokenizerLoader = #huggingFaceTokenizerLoader()
        let container: ModelContainer
        if request.vision {
            container = try await VLMModelFactory.shared.loadContainer(from: directory, using: tokenizerLoader)
        } else {
            container = try await LLMModelFactory.shared.loadContainer(from: directory, using: tokenizerLoader)
        }
        var parameters = GenerateParameters()
        parameters.maxTokens = request.maxTokens
        var temporaryImages: [URL] = []
        defer { for url in temporaryImages { try? FileManager.default.removeItem(at: url) } }
        var messages: [Chat.Message] = []
        for item in request.messages {
            var images: [UserInput.Image] = []
            for value in item.imageURLs ?? [] {
                guard request.vision, value.hasPrefix("data:image/"),
                      let comma = value.firstIndex(of: ","), value[..<comma].contains(";base64"),
                      let data = Data(base64Encoded: String(value[value.index(after: comma)...])), data.count <= 10_000_000 else {
                    throw RunnerError.invalidImage
                }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("stix-mlx-" + UUID().uuidString + ".png")
                try data.write(to: url, options: .atomic)
                temporaryImages.append(url)
                images.append(.url(url))
            }
            switch item.role {
            case "system": messages.append(.system(item.content))
            case "user": messages.append(.user(item.content, images: images))
            case "assistant": messages.append(.assistant(item.content))
            case "tool": messages.append(.tool(item.content))
            default: throw RunnerError.invalidArguments
            }
        }
        let session = ChatSession(container, generateParameters: parameters,
                                  additionalContext: ["enable_thinking": false])
        for try await item in session.streamDetails(to: messages) {
            switch item {
            case .chunk(let text): emit(Event(type: "text", text: text, name: nil, arguments: nil, id: nil))
            case .toolCall(let call):
                let data = try JSONEncoder().encode(call.function.arguments)
                emit(Event(type: "tool", text: nil, name: call.function.name,
                           arguments: String(decoding: data, as: UTF8.self), id: call.id))
            case .rejectedToolCall(let rejection):
                emit(Event(type: "error", text: String(describing: rejection), name: nil, arguments: nil, id: nil))
            case .info: break
            }
        }
        emit(Event(type: "done", text: nil, name: nil, arguments: nil, id: nil))
    }
}

private enum RunnerError: LocalizedError {
    case invalidArguments, missingModel, invalidImage
    var errorDescription: String? {
        switch self {
        case .invalidArguments: "Некорректный запрос к локальному MLX-движку"
        case .missingModel: "Локальная MLX-модель не найдена"
        case .invalidImage: "Некорректное изображение для MLX-модели"
        }
    }
}
