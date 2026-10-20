import Foundation

struct ThinkingDelta: Equatable {
    var text = ""
    var reasoning = ""
}

/// Separates inline reasoning without retaining it. Partial delimiters stay buffered across tokens.
struct ThinkingStream {
    private var pending = ""
    private var closingDelimiter: String?
    private static let openings = [("<think>", "</think>"), ("<|channel>thought", "<channel|>")]

    mutating func consume(_ chunk: String, finishing: Bool = false) -> ThinkingDelta {
        pending += chunk
        var output = ThinkingDelta()
        while !pending.isEmpty {
            let options = closingDelimiter.map { [($0, "")] } ?? Self.openings
            let next = options.compactMap { opening, closing -> (Range<String.Index>, String)? in
                pending.range(of: opening).map { ($0, closing) }
            }.min { $0.0.lowerBound < $1.0.lowerBound }
            if let (range, closing) = next {
                let prefix = String(pending[..<range.lowerBound])
                if closingDelimiter != nil { output.reasoning += prefix } else { output.text += prefix }
                pending = String(pending[range.upperBound...])
                closingDelimiter = closingDelimiter == nil ? closing : nil
            } else {
                var retained = 0
                if !finishing {
                    for (delimiter, _) in options {
                        for length in 1..<delimiter.count where pending.hasSuffix(String(delimiter.prefix(length))) {
                            retained = max(retained, length)
                        }
                    }
                }
                let prefix = String(pending.dropLast(retained))
                if closingDelimiter != nil { output.reasoning += prefix } else { output.text += prefix }
                pending = retained == 0 ? "" : String(pending.suffix(retained))
                break
            }
        }
        return output
    }
}
