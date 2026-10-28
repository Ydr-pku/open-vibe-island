import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum EndpointParser {
    static func parse(_ input: String) throws -> SSHEndpoint {
        var tokens = input.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { throw invalid("请输入 SSH 地址。") }
        let isCommand = tokens.first == "ssh"
        if isCommand { tokens.removeFirst() }
        var address: String?
        var explicitPort: Int?
        while !tokens.isEmpty {
            let token = tokens.removeFirst()
            if isCommand && (token == "-p" || token.hasPrefix("-p")) {
                guard explicitPort == nil else { throw invalid("SSH 端口只能指定一次。") }
                let value: String
                if token == "-p" {
                    guard !tokens.isEmpty else { throw invalid("-p 后需要端口号。") }
                    value = tokens.removeFirst()
                } else {
                    value = String(token.dropFirst(2))
                }
                explicitPort = try port(value)
            } else {
                guard !token.hasPrefix("-"), address == nil else {
                    throw invalid("只接受 SSH 主机、用户名和 -p 端口，不接受其他选项或远程命令。")
                }
                address = token
            }
        }
        guard let address else { throw invalid("请输入 SSH 主机。") }
        let userParts = address.components(separatedBy: "@")
        guard userParts.count <= 2 else { throw invalid("SSH 用户名或地址格式无效。") }
        let user = userParts.count == 2 ? userParts[0] : "root"
        guard matches(user, #"^[A-Za-z0-9_][A-Za-z0-9_.-]*$"#) else {
            throw invalid("SSH 用户名格式无效。")
        }
        var host = userParts.last!
        var addressPort: Int?
        if host.hasPrefix("[") {
            guard let end = host.firstIndex(of: "]") else { throw invalid("IPv6 地址缺少右方括号。") }
            let tail = String(host[host.index(after: end)...])
            let literal = String(host[host.index(after: host.startIndex)..<end])
            guard validIPv6(literal) else { throw invalid("IPv6 地址无效。") }
            if !tail.isEmpty {
                guard tail.hasPrefix(":") else { throw invalid("IPv6 地址后只能指定端口。") }
                addressPort = try port(String(tail.dropFirst()))
            }
            host = literal
        } else if host.filter({ $0 == ":" }).count == 1 {
            let parts = host.components(separatedBy: ":")
            host = parts[0]
            addressPort = try port(parts[1])
        } else if host.contains(":") {
            guard validIPv6(host) else { throw invalid("IPv6 地址无效；带端口时请写为 [地址]:端口。") }
        }
        if !host.contains(":") {
            guard matches(host, #"^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$"#),
                  !host.contains(".."), host.count <= 253,
                  host.components(separatedBy: ".").allSatisfy({ !$0.hasPrefix("-") && !$0.hasSuffix("-") && $0.count <= 63 }) else {
                throw invalid("SSH 主机地址无效。")
            }
            if matches(host, #"^[0-9.]+$"#), host.contains(".") {
                let octets = host.components(separatedBy: ".")
                guard octets.count == 4, octets.allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false }) else {
                    throw invalid("IPv4 地址无效。")
                }
            }
        }
        guard explicitPort == nil || addressPort == nil else { throw invalid("SSH 端口只能指定一次。") }
        return SSHEndpoint(host: host, port: explicitPort ?? addressPort ?? 22, user: user)
    }

    private static func port(_ value: String) throws -> Int {
        guard matches(value, #"^[0-9]+$"#), let number = Int(value), (1...65535).contains(number) else {
            throw invalid("SSH 端口应为 1 到 65535 的整数。")
        }
        return number
    }
    private static func validIPv6(_ value: String) -> Bool {
        var address = in6_addr()
        return value.withCString { inet_pton(AF_INET6, $0, &address) } == 1
    }
    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
    private static func invalid(_ message: String) -> MonitorError { .invalidEndpoint(message) }
}
