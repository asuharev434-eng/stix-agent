import Foundation

/// Explicit credential references are resolved only after the caller obtains execution approval.
enum CredentialEnvironment {
    static func validateName(_ name: String) throws {
        let blocked = ["PATH", "HOME", "SHELL", "ENV", "BASH_ENV", "ZDOTDIR", "TMPDIR", "IFS", "CDPATH", "GLOBIGNORE", "PYTHONPATH", "PYTHONHOME", "NODE_OPTIONS", "NODE_PATH", "RUBYOPT", "RUBYLIB", "PERL5OPT", "PERL5LIB", "JAVA_TOOL_OPTIONS", "JDK_JAVA_OPTIONS", "CLASSPATH", "SSL_CERT_FILE", "SSL_CERT_DIR", "CURL_CA_BUNDLE", "REQUESTS_CA_BUNDLE", "GIT_CONFIG", "GIT_CONFIG_COUNT", "GIT_SSH", "GIT_SSH_COMMAND", "GIT_ASKPASS", "SSH_ASKPASS", "EDITOR", "VISUAL", "PAGER", "LESSOPEN", "LESSCLOSE", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "TERMINFO", "TERMINFO_DIRS"]
        guard name.range(of: "^[A-Z_][A-Z0-9_]{0,127}$", options: .regularExpression) != nil,
              !blocked.contains(name), !["DYLD_", "LD_", "GIT_", "BASH_", "ZSH", "PYTHON", "NODE_", "RUBY", "PERL", "JAVA_", "JDK_", "LC_"].contains(where: name.hasPrefix) else {
            throw AgentError.message("Недопустимое имя переменной окружения")
        }
    }
    static func validate(environment: [String: String]) throws {
        guard environment.count <= 32 else { throw AgentError.message("Слишком много переменных с секретами") }
        for (name, value) in environment {
            try validateName(name)
            guard !value.isEmpty, value.utf8.count <= 16384, !value.contains("\0") else { throw AgentError.message("Недопустимое значение секрета окружения") }
        }
    }
    static func resolve(_ references: [String: String], vault: SecretVault) throws -> [String: String] {
        guard references.count <= 32 else { throw AgentError.message("Слишком много ссылок на секреты") }
        var result: [String: String] = [:]
        for (name, id) in references {
            try validateName(name)
            guard !id.isEmpty, id.utf8.count <= 256, !id.contains("\0") else { throw AgentError.message("Недопустимая ссылка на секрет") }
            result[name] = try vault.get(id)
        }
        try validate(environment: result)
        return result
    }
}
