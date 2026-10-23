import Foundation

/// A local image request. Paths refer to local files, never remote URLs.
struct ImageRequest: Sendable, Equatable, Codable {
    static let defaultNegativePrompt = "low quality, blurry, distorted, watermark"
    static func isImageCommand(_ text: String) -> Bool {
        ["/image", "/image2image"].contains { text == $0 || text.hasPrefix($0 + " ") || text.hasPrefix($0 + "\n") }
    }
    var prompt: String
    var inputImagePath: String?
    var maskImagePath: String?
    var width: Int = 1024
    var height: Int = 1024
    var steps: Int = 20
    /// Restricted to exact JSON integers (IEEE-754).
    var seed: UInt64 = UInt64.random(in: 0...UInt64(Int32.max))
    var cfg: Double = 7
    var denoise: Double = 1
    var negativePrompt: String = Self.defaultNegativePrompt
    var count: Int = 1
    var resizeOnly: Bool = false
    /// Used to reject custom workflows that would silently ignore chat options.
    var explicitOptions: Set<String> = []

    func validated() throws -> ImageRequest {
        guard (resizeOnly || !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty), prompt.utf8.count <= 64_000 else {
            throw AgentError.message("Описание изображения пустое или слишком длинное")
        }
        guard negativePrompt.utf8.count <= 64_000 else { throw AgentError.message("Негативное описание слишком длинное") }
        guard (256...2048).contains(width), (256...2048).contains(height), width % 8 == 0, height % 8 == 0,
              width * height <= 2048 * 2048 else { throw AgentError.message("Размер изображения: 256–2048 пикселей, стороны кратны 8") }
        guard (1...100).contains(steps) else { throw AgentError.message("Количество шагов: от 1 до 100") }
        guard seed <= 9_007_199_254_740_991 else { throw AgentError.message("Seed должен быть от 0 до 9007199254740991") }
        guard cfg.isFinite, (0...30).contains(cfg) else { throw AgentError.message("CFG должен быть от 0 до 30") }
        guard denoise.isFinite, (0...1).contains(denoise) else { throw AgentError.message("Denoise должен быть от 0 до 1") }
        guard (1...4).contains(count) else { throw AgentError.message("Количество вариантов: от 1 до 4") }
        if resizeOnly {
            guard inputImagePath != nil else { throw AgentError.message("Для --resize-only требуется исходное изображение --input") }
            guard maskImagePath == nil, count == 1,
                  explicitOptions.isDisjoint(with: ["steps", "seed", "cfg", "denoise", "negative", "count"]) else {
                throw AgentError.message("--resize-only поддерживает только исходное изображение и размер; параметры генерации и маска недопустимы")
            }
        }
        guard maskImagePath == nil || inputImagePath != nil else { throw AgentError.message("Для маски требуется исходное изображение --input") }
        for path in [inputImagePath, maskImagePath].compactMap({ $0 }) {
            guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 4096 else {
                throw AgentError.message("Укажите абсолютный локальный путь изображения")
            }
        }
        guard inputImagePath != nil || denoise == 1 else { throw AgentError.message("Denoise ниже 1 требует исходное изображение --input") }
        return self
    }

    /// Quoted values support spaces; backslashes escape quotes/backslashes inside quotes.
    static func parse(_ command: String, lastImagePath: String? = nil, inputImagePath: String? = nil, maskImagePath: String? = nil) throws -> ImageRequest {
        var tokens = try tokenize(command)
        let editing = tokens.first == "/image2image"
        if tokens.first == "/image" || editing { tokens.removeFirst() }
        var result = ImageRequest(prompt: "", inputImagePath: inputImagePath, maskImagePath: maskImagePath)
        var prompt: [String] = []
        var index = 0
        var literal = false
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            if token == "--", !literal { literal = true; continue }
            guard !literal, token.hasPrefix("--") else { prompt.append(token); continue }
            let pair = token.dropFirst(2).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(pair[0])
            let allowed = ["input", "mask", "size", "width", "height", "steps", "seed", "cfg", "denoise", "negative", "count", "resize-only"]
            guard allowed.contains(key) else { throw AgentError.message("Неизвестный параметр /image: --\(key)") }
            guard !result.explicitOptions.contains(key) else { throw AgentError.message("Параметр --\(key) указан повторно") }
            result.explicitOptions.insert(key)
            if key == "resize-only" {
                guard pair.count == 1 else { throw AgentError.message("--resize-only указывается без значения") }
                result.resizeOnly = true
                continue
            }
            let value: String
            if pair.count == 2 { value = String(pair[1]) }
            else {
                guard index < tokens.count, !tokens[index].hasPrefix("--") else { throw AgentError.message("Для --\(key) требуется значение") }
                value = tokens[index]; index += 1
            }
            func integer() throws -> Int {
                guard let number = Int(value) else { throw AgentError.message("Для --\(key) требуется целое число") }
                return number
            }
            func decimal() throws -> Double {
                guard let number = Double(value) else { throw AgentError.message("Для --\(key) требуется число") }
                return number
            }
            switch key {
            case "input":
                if ["last", "latest"].contains(value.lowercased()) {
                    guard let lastImagePath else { throw AgentError.message("В этом чате ещё нет созданного изображения") }
                    result.inputImagePath = lastImagePath
                } else { result.inputImagePath = value }
            case "mask": result.maskImagePath = value
            case "width": result.width = try integer()
            case "height": result.height = try integer()
            case "steps": result.steps = try integer()
            case "seed":
                guard let seed = UInt64(value) else { throw AgentError.message("Seed должен быть неотрицательным целым числом") }
                result.seed = seed
            case "cfg": result.cfg = try decimal()
            case "denoise": result.denoise = try decimal()
            case "negative": result.negativePrompt = value
            case "count": result.count = try integer()
            case "size":
                let parts = value.lowercased().split(separator: "x")
                guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]) else { throw AgentError.message("Размер задаётся как --size 1024x1024") }
                result.width = width; result.height = height
            default: break
            }
        }
        guard !result.explicitOptions.contains("size") || result.explicitOptions.isDisjoint(with: ["width", "height"]) else {
            throw AgentError.message("Используйте --size или --width/--height")
        }
        result.prompt = prompt.joined(separator: " ")
        if editing, result.inputImagePath == nil { result.inputImagePath = lastImagePath }
        if editing, result.inputImagePath == nil {
            throw AgentError.message("Для /image2image прикрепите фото или создайте картинку в этом чате. Можно указать --input /путь/к/файлу")
        }
        if result.inputImagePath != nil, !result.explicitOptions.contains("denoise") { result.denoise = 0.75 }
        return try result.validated()
    }

    private static func tokenize(_ text: String) throws -> [String] {
        var tokens: [String] = [], token = ""
        var quote: Character?, escaped = false, started = false
        for char in text {
            if escaped { token.append(char); escaped = false; started = true; continue }
            if char == "\\", quote != "'" { escaped = true; started = true; continue }
            if let current = quote {
                if char == current { quote = nil } else { token.append(char) }
                started = true
            } else if char == "\"" || char == "'" { quote = char; started = true }
            else if char.isWhitespace {
                if started { tokens.append(token); token = ""; started = false }
            } else { token.append(char); started = true }
        }
        guard quote == nil, !escaped else { throw AgentError.message("Незакрытая кавычка или escape в /image") }
        if started { tokens.append(token) }
        return tokens
    }
}

extension ImageRequest {
    private enum CodingKeys: String, CodingKey {
        case prompt, inputImagePath, maskImagePath, width, height, steps, seed, cfg,
             denoise, negativePrompt, count, resizeOnly, explicitOptions
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        prompt = try values.decode(String.self, forKey: .prompt)
        inputImagePath = try values.decodeIfPresent(String.self, forKey: .inputImagePath)
        maskImagePath = try values.decodeIfPresent(String.self, forKey: .maskImagePath)
        width = try values.decode(Int.self, forKey: .width)
        height = try values.decode(Int.self, forKey: .height)
        steps = try values.decode(Int.self, forKey: .steps)
        seed = try values.decode(UInt64.self, forKey: .seed)
        cfg = try values.decode(Double.self, forKey: .cfg)
        denoise = try values.decode(Double.self, forKey: .denoise)
        negativePrompt = try values.decode(String.self, forKey: .negativePrompt)
        count = try values.decode(Int.self, forKey: .count)
        resizeOnly = try values.decode(Bool.self, forKey: .resizeOnly)
        explicitOptions = Set(try values.decodeIfPresent([String].self, forKey: .explicitOptions) ?? [])
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(prompt, forKey: .prompt)
        try values.encodeIfPresent(inputImagePath, forKey: .inputImagePath)
        try values.encodeIfPresent(maskImagePath, forKey: .maskImagePath)
        try values.encode(width, forKey: .width)
        try values.encode(height, forKey: .height)
        try values.encode(steps, forKey: .steps)
        try values.encode(seed, forKey: .seed)
        try values.encode(cfg, forKey: .cfg)
        try values.encode(denoise, forKey: .denoise)
        try values.encode(negativePrompt, forKey: .negativePrompt)
        try values.encode(count, forKey: .count)
        try values.encode(resizeOnly, forKey: .resizeOnly)
        try values.encode(explicitOptions.sorted(), forKey: .explicitOptions)
    }
}
