import Foundation

/// The story protocol's numeric expressions, never JavaScript evaluation.
/// Unknown variables/operators and non-finite results stop a choice explicitly.
enum InteractiveExpression {
    struct Invalid: LocalizedError {
        let errorDescription: String? = "无法解析此视频的剧情条件"
    }

    static func evaluate(_ source: String, variables: [String: Double]) throws -> Double {
        var parser = try Parser(source, variables: variables)
        let result = try parser.expression()
        guard parser.index == parser.tokens.count, result.isFinite else { throw Invalid() }
        return result
    }

    static func applying(_ actions: String, to variables: [String: Double]) throws -> [String: Double] {
        guard actions.count <= 8192 else { throw Invalid() }
        var result = variables
        for statement in actions.split(whereSeparator: { $0 == ";" || $0.isNewline }) {
            if statement.allSatisfy(\.isWhitespace) { continue }
            let parts = statement.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { throw Invalid() }
            let name = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard result[name] != nil else { throw Invalid() }
            result[name] = try evaluate(parts[1], variables: result)
        }
        return result
    }

    private struct Parser {
        var tokens: [String] = []
        var index = 0
        let variables: [String: Double]
        var depth = 0

        init(_ source: String, variables: [String: Double]) throws {
            guard source.count <= 8192 else { throw Invalid() }
            self.variables = variables
            let chars = Array(source)
            var i = 0
            while i < chars.count {
                let c = chars[i]
                if c.isWhitespace { i += 1; continue }
                let start = i
                if c == "$" || c == "_" || c.isASCII && c.isLetter {
                    i += 1
                    while i < chars.count, chars[i] == "_" || chars[i].isASCII && (chars[i].isLetter || chars[i].isNumber) { i += 1 }
                } else if c.isASCII && c.isNumber || c == "." {
                    i += 1
                    while i < chars.count, chars[i].isASCII && chars[i].isNumber || chars[i] == "." { i += 1 }
                } else {
                    if i + 1 < chars.count, ["&&", "||", "==", "!=", "<=", ">="].contains(String(chars[i...i+1])) {
                        i += 2
                    } else {
                        guard "+-*/%()!<>".contains(c) else { throw Invalid() }
                        i += 1
                    }
                }
                tokens.append(String(chars[start..<i]))
                guard tokens.count <= 2048 else { throw Invalid() }
            }
        }

        mutating func take(_ token: String) -> Bool {
            guard index < tokens.count, tokens[index] == token else { return false }
            index += 1; return true
        }
        mutating func expression() throws -> Double {
            // Bilibili's story interpreter treats AND/OR at the same
            // precedence, left to right (unlike JavaScript/Swift).
            var value = try comparison()
            while index < tokens.count, ["&&", "||"].contains(tokens[index]) {
                let op = tokens[index]; index += 1
                let rhs = try comparison()
                value = op == "&&" ? (value != 0 && rhs != 0 ? 1 : 0) : (value != 0 || rhs != 0 ? 1 : 0)
            }
            return value
        }
        mutating func comparison() throws -> Double {
            var value = try sum()
            while index < tokens.count, ["==", "!=", "<", ">", "<=", ">="].contains(tokens[index]) {
                let op = tokens[index]; index += 1
                let rhs = try sum()
                switch op {
                case "==": value = value == rhs ? 1 : 0
                case "!=": value = value != rhs ? 1 : 0
                case "<": value = value < rhs ? 1 : 0
                case ">": value = value > rhs ? 1 : 0
                case "<=": value = value <= rhs ? 1 : 0
                default: value = value >= rhs ? 1 : 0
                }
            }
            return value
        }
        mutating func sum() throws -> Double {
            var value = try product()
            while index < tokens.count, ["+", "-"].contains(tokens[index]) {
                let op = tokens[index]; index += 1
                let rhs = try product(); value = op == "+" ? value + rhs : value - rhs
            }
            return value
        }
        mutating func product() throws -> Double {
            var value = try unary()
            while index < tokens.count, ["*", "/", "%"].contains(tokens[index]) {
                let op = tokens[index]; index += 1
                let rhs = try unary()
                if op != "*", rhs == 0 { throw Invalid() }
                switch op { case "*": value *= rhs; case "/": value /= rhs; default: value = value.truncatingRemainder(dividingBy: rhs) }
            }
            guard value.isFinite else { throw Invalid() }
            return value
        }
        mutating func unary() throws -> Double {
            depth += 1
            defer { depth -= 1 }
            guard depth <= 64 else { throw Invalid() }
            if take("!") { return try unary() == 0 ? 1 : 0 }
            if take("-") { return try -unary() }
            if take("+") { return try unary() }
            if take("(") {
                let value = try expression()
                guard take(")") else { throw Invalid() }
                return value
            }
            guard index < tokens.count else { throw Invalid() }
            let token = tokens[index]; index += 1
            if let value = Double(token), value.isFinite { return value }
            guard let value = variables[token], value.isFinite else { throw Invalid() }
            return value
        }
    }
}
