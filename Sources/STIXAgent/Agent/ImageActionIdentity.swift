import Foundation

enum ImageActionIdentity {
    /// The same edit description and source within one user turn is a duplicate,
    /// even when a weak model changes optional parameters after a successful result.
    /// Different descriptions/sources remain separate actions. Resize has no costly
    /// generation side effect and may legitimately produce several output sizes.
    static func key(_ args: JSONValue) -> String? {
        guard args["resize_only"].bool != true, let prompt = args["prompt"].string,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return JSONValue.array([
            .string(prompt.trimmingCharacters(in: .whitespacesAndNewlines)),
            .string(args["input_image"].string ?? ""),
            .string(args["mask"].string ?? ""), .string(args["negative"].string ?? ""),
            args["seed"], args["denoise"]
        ]).encoded
    }
}
