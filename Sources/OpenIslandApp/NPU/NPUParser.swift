import Foundation

enum NPUParser {
    private struct Field {
        let name: String
        let cell: Int
        let start: Int
        let end: Int?
    }
    private struct Header {
        let fields: [Field]
        init(_ cells: [String], names: [String]) {
            var result: [Field] = []
            for (index, cell) in cells.enumerated() {
                let ns = cell as NSString
                let locations = names.compactMap { name -> (String, Int)? in
                    let range = ns.range(of: name)
                    return range.location == NSNotFound ? nil : (name, range.location)
                }.sorted { $0.1 < $1.1 }
                for (offset, item) in locations.enumerated() {
                    result.append(Field(name: item.0, cell: index, start: item.1,
                                        end: offset + 1 < locations.count ? locations[offset + 1].1 : nil))
                }
            }
            fields = result
        }
        func value(_ name: String, in cells: [String]) -> String? {
            guard let field = fields.first(where: { $0.name == name }), field.cell < cells.count else { return nil }
            let value = cells[field.cell] as NSString
            guard field.start < value.length else { return "" }
            let end = min(field.end ?? value.length, value.length)
            return value.substring(with: NSRange(location: field.start, length: max(0, end - field.start)))
                .trimmingCharacters(in: .whitespaces)
        }
    }

    static func parse(_ text: String, at date: Date = Date()) throws -> NPUSnapshot {
        let cleaned = text.replacingOccurrences(of: #"\x1B\[[0-?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "")
        var lines = cleaned.components(separatedBy: "\n")
        guard let versionIndex = lines.lastIndex(where: { $0.range(of: #"\bnpu-smi\s+\S+.*Version:"#, options: .regularExpression) != nil }) else {
            throw MonitorError.invalidOutput("未找到 npu-smi 信息表。请检查登录环境与驱动是否可用。")
        }
        lines = Array(lines[versionIndex...])
        let versionLine = lines[0]
        let version = versionLine.range(of: #"Version:\s*([^\s|]+)"#, options: .regularExpression)
            .map { String(versionLine[$0]).replacingOccurrences(of: "Version:", with: "").trimmingCharacters(in: .whitespaces) } ?? "未知"
        var topHeader: Header?
        var bottomHeader: Header?
        var current: NPUDevice?
        var awaitingChip = false
        var devices: [NPUDevice] = []
        var processes: [NPUProcess] = []
        var inProcesses = false
        var processRows = 0
        var processEnd = false
        var processNPUs = Set<Int>()
        for line in lines.dropFirst() {
            guard let cells = tableCells(line) else {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    throw malformed("数据行被截断")
                }
                if inProcesses && processRows > 0 && isBorder(line) { processEnd = true }
                continue
            }
            if cells.joined().contains("Process id") {
                inProcesses = true
                continue
            }
            if inProcesses {
                let joined = cells.joined(separator: " ")
                if joined.contains("No running processes") {
                    if let match = joined.range(of: #"NPU\s+\d+"#, options: .regularExpression),
                       let npu = Int(joined[match].split(whereSeparator: \.isWhitespace).last ?? "") {
                        processNPUs.insert(npu)
                    } else {
                        processNPUs.formUnion(devices.map(\.npuID))
                    }
                    processRows += 1
                    processEnd = false
                    continue
                }
                guard cells.count >= 4 else { throw malformed("进程数据行格式无效") }
                let identifiers = cells[0].split(whereSeparator: \.isWhitespace)
                if identifiers.count == 2, let npu = Int(identifiers[0]), let chip = Int(identifiers[1]),
                   let pid = Int(cells[1].trimmingCharacters(in: .whitespaces)) {
                    let process = NPUProcess(npuID: npu, chipID: chip, pid: pid,
                        name: cells[2].trimmingCharacters(in: .whitespaces),
                        memoryMB: try number(cells[3], field: "进程内存"))
                    processes.append(process)
                    processNPUs.insert(npu)
                    processRows += 1
                    processEnd = false
                } else if !joined.trimmingCharacters(in: .whitespaces).isEmpty {
                    throw malformed("进程数据行格式无效")
                }
                continue
            }
            if cells.joined().contains("Power(W)") && cells.joined().contains("Health") {
                topHeader = Header(cells, names: ["NPU", "Name", "Health", "Power(W)", "Temp(C)", "Hugepages-Usage(page)"])
                continue
            }
            if cells.joined().contains("AICore(%)") {
                bottomHeader = Header(cells, names: ["Chip", "Bus-Id", "AICore(%)", "Memory-Usage(MB)", "HBM-Usage(MB)"])
                continue
            }
            guard let topHeader, let bottomHeader else { continue }
            if let npuText = topHeader.value("NPU", in: cells), let npu = Int(npuText),
               let name = topHeader.value("Name", in: cells), !name.isEmpty {
                guard !awaitingChip else { throw malformed("设备缺少 Chip 数据行") }
                let health = topHeader.value("Health", in: cells) ?? "未知"
                current = NPUDevice(npuID: npu, chipID: 0, name: name, health: health.isEmpty ? "未知" : health,
                    busID: "", powerWatts: try number(topHeader.value("Power(W)", in: cells), field: "功耗"),
                    temperatureC: try number(topHeader.value("Temp(C)", in: cells), field: "温度", allowNegative: true),
                    utilization: nil, memoryUsedMB: nil, memoryTotalMB: nil, hbmUsedMB: nil, hbmTotalMB: nil)
                awaitingChip = true
            } else if let chipText = bottomHeader.value("Chip", in: cells), let chip = Int(chipText), var device = current {
                device.chipID = chip
                device.busID = bottomHeader.value("Bus-Id", in: cells) ?? ""
                device.utilization = try number(bottomHeader.value("AICore(%)", in: cells), field: "AICore 利用率")
                if let utilization = device.utilization, utilization > 100 { throw malformed("AICore 利用率超出范围") }
                let memory = try memoryPair(bottomHeader.value("Memory-Usage(MB)", in: cells), field: "Memory")
                let hbm = try memoryPair(bottomHeader.value("HBM-Usage(MB)", in: cells), field: "HBM")
                device.memoryUsedMB = memory.0
                device.memoryTotalMB = memory.1
                device.hbmUsedMB = hbm.0
                device.hbmTotalMB = hbm.1
                guard !devices.contains(where: { $0.id == device.id }) else { throw malformed("设备 ID 重复") }
                devices.append(device)
                awaitingChip = false
            } else if cells.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                throw malformed("设备数据行格式无效")
            }
        }
        guard !devices.isEmpty, !awaitingChip, inProcesses, processRows > 0, processEnd,
              Set(devices.map(\.npuID)).isSubset(of: processNPUs) else {
            throw malformed("输出不完整，或设备表格式暂不支持")
        }
        return NPUSnapshot(timestamp: date, version: version, devices: devices, processes: processes, rawOutput: text)
    }

    private static func tableCells(_ line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|"), trimmed.hasSuffix("|") else { return nil }
        return Array(trimmed.components(separatedBy: "|").dropFirst().dropLast())
    }
    private static func isBorder(_ line: String) -> Bool {
        let value = line.trimmingCharacters(in: .whitespaces)
        return value.hasPrefix("+") && value.hasSuffix("+") && value.contains(where: { $0 == "-" || $0 == "=" })
    }
    private static func number(_ value: String?, field: String, allowNegative: Bool = false) throws -> Double? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespaces)
        if ["N/A", "NA", "--", "-", "UNKNOWN"].contains(clean.uppercased()) { return nil }
        guard !clean.isEmpty, let result = Double(clean), result.isFinite, allowNegative || result >= 0 else {
            throw malformed("\(field)数值无效")
        }
        return result
    }
    private static func memoryPair(_ value: String?, field: String) throws -> (Double?, Double?) {
        guard let value else { return (nil, nil) }
        let clean = value.trimmingCharacters(in: .whitespaces)
        if ["N/A", "NA", "--", "-"].contains(clean.uppercased()) { return (nil, nil) }
        let valuePattern = #"(N/A|NA|--|-|[0-9]+(?:\.[0-9]+)?)"#
        let regex = try NSRegularExpression(pattern: #"^\s*"# + valuePattern + #"\s*/\s*"# + valuePattern + #"\s*$"#,
                                            options: .caseInsensitive)
        let ns = clean as NSString
        guard let match = regex.firstMatch(in: clean, range: NSRange(location: 0, length: ns.length)) else {
            throw malformed("\(field)内存格式无效")
        }
        return (try number(ns.substring(with: match.range(at: 1)), field: field),
                try number(ns.substring(with: match.range(at: 2)), field: field))
    }
    private static func malformed(_ message: String) -> MonitorError { .invalidOutput("npu-smi 解析失败：\(message)。") }
}
