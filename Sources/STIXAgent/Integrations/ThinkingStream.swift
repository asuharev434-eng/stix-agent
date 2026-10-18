import Foundation

struct ThinkingDelta: Equatable {
    var text = ""
    var reasoning = ""
}

/// Separates inline reasoning without retaining it. Partial delimiters stay buffered across tokens.
struct ThinkingStream {
    private var pending = ""
    private var insideThinking = false

    mutating func consume(_ chunk: String, finishing: Bool = false) -> ThinkingDelta {
        pending += chunk
        var output = ThinkingDelta()
        while !pending.isEmpty {
            let delimiter = insideThinking ? "</think>" : "<think>"
            if let range = pending.range(of: delimiter) {
                let prefix = String(pending[..<range.lowerBound])
                if insideThinking { output.reasoning += prefix } else { output.text += prefix }
                pending = String(pending[range.upperBound...])
                insideThinking.toggle()
            } else {
                var retained = 0
                if !finishing {
                    for length in 1..<delimiter.count where pending.hasSuffix(String(delimiter.prefix(length))) { retained = length }
                }
                let prefix = String(pending.dropLast(retained))
                if insideThinking { output.reasoning += prefix } else { output.text += prefix }
                pending = retained == 0 ? "" : String(pending.suffix(retained))
                break
            }
        }
        return output
    }
}
