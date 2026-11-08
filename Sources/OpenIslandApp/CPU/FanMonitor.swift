import Foundation

struct FanReading: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let rpm: Double?
    let maximumRPM: Double?

    var percentage: Double? {
        guard let rpm, let maximumRPM, maximumRPM > 0 else { return nil }
        return rpm / maximumRPM * 100
    }

    // These colors express rotation speed, not temperature or fan health.
    // Without a hardware maximum, use explicit absolute RPM bands instead.
    var speedBand: Int? {
        guard let rpm else { return nil }
        if let percentage { return percentage >= 80 ? 2 : (percentage >= 50 ? 1 : 0) }
        return rpm >= 4_000 ? 2 : (rpm >= 2_000 ? 1 : 0)
    }
}

struct FanSnapshot: Decodable, Equatable, Sendable {
    let fans: [FanReading]

    static func decode(_ data: Data) throws -> Self {
        try validated(JSONDecoder().decode(Self.self, from: data))
    }

    private static func validated(_ sample: Self) throws -> Self {
        guard sample.fans.count <= 32,
              Set(sample.fans.map(\.id)).count == sample.fans.count,
              sample.fans.allSatisfy({ fan in
                  !fan.id.isEmpty && !fan.name.isEmpty &&
                  (fan.rpm.map { $0.isFinite && (0...100_000).contains($0) } ?? true) &&
                  (fan.maximumRPM.map { $0.isFinite && (1...100_000).contains($0) } ?? true)
              }) else { throw FanCollectionError.invalidSample }
        return sample
    }

    static func decodeWindows(_ data: Data) throws -> Self {
        let encoding: String.Encoding = data.contains(0) ? .utf16LittleEndian : .utf8
        guard let text = String(data: data, encoding: encoding) else { throw FanCollectionError.invalidSample }
        let lines = text.replacingOccurrences(of: "\u{feff}", with: "")
            .replacingOccurrences(of: "\r", with: "").split(separator: "\n").map(String.init)
        guard let first = lines.first else { throw FanCollectionError.invalidSample }
        let header = try csvFields(first)
        let required = ["DeviceID", "Name", "SensorType", "BaseUnits", "RateUnits", "UnitModifier", "CurrentReading", "CurrentState"]
        guard Set(header).count == header.count, required.allSatisfy(header.contains) else {
            throw FanCollectionError.invalidSample
        }
        let fans = try lines.dropFirst().map { line -> FanReading in
            let values = try csvFields(line)
            guard values.count == header.count else { throw FanCollectionError.invalidSample }
            let fields = Dictionary(uniqueKeysWithValues: zip(header, values))
            guard fields["SensorType"] == "5", fields["BaseUnits"] == "19", fields["RateUnits"] == "0",
                  let exponent = Int(fields["UnitModifier"] ?? ""), (-6...6).contains(exponent) else {
                throw FanCollectionError.invalidSample
            }
            let state = (fields["CurrentState"] ?? "").lowercased()
            let unavailable = state.isEmpty || ["n/a", "unknown", "not present", "not installed", "unavailable"].contains(state)
            let raw = Double(fields["CurrentReading"] ?? "")
            guard unavailable || raw != nil else { throw FanCollectionError.invalidSample }
            return FanReading(id: fields["DeviceID"] ?? "", name: fields["Name"] ?? "",
                              rpm: unavailable ? nil : raw.map { $0 * pow(10, Double(exponent)) }, maximumRPM: nil)
        }
        // WMI MaxReadable and NormalMax describe sensor ranges. They are not
        // the physical fan's maximum, so deliberately do not use them here.
        return try validated(Self(fans: fans))
    }

    private static func csvFields(_ line: String) throws -> [String] {
        var fields: [String] = [], field = "", quoted = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            let next = line.index(after: index)
            if character == "\"" {
                if quoted, next < line.endIndex, line[next] == "\"" {
                    field.append("\"")
                    index = line.index(after: next)
                    continue
                }
                quoted.toggle()
            } else if character == ",", !quoted {
                fields.append(field); field = ""
            } else {
                field.append(character)
            }
            index = next
        }
        guard !quoted else { throw FanCollectionError.invalidSample }
        fields.append(field)
        return fields
    }
}

enum FanCollectionError: LocalizedError {
    case invalidSample, missingCollector, timedOut

    var errorDescription: String? {
        switch self {
        case .invalidSample: return LanguageManager.shared.t("fan.error.sample")
        case .missingCollector: return LanguageManager.shared.t("fan.error.collector")
        case .timedOut: return LanguageManager.shared.t("fan.error.timeout")
        }
    }
}

enum FanCollector {
    static func supports(_ alias: String) -> Bool { ["macserver", "winserver2055"].contains(alias) }

    static func sample(alias: String) async throws -> FanSnapshot {
        guard supports(alias) else { throw FanCollectionError.invalidSample }
        let target: String
        let command: String
        let input: Data
        if alias == "winserver2055" {
            target = "winserver2055-windows"
            command = #"wmic /namespace:\\root\Hardware path NumericSensor where "SensorType=5" get Name,DeviceID,SensorType,CurrentReading,BaseUnits,UnitModifier,RateUnits,CurrentState /format:csv"#
            input = Data()
        } else {
            target = alias
            command = "python3 -"
            guard let script = Bundle.appResources.url(forResource: "fan-sample", withExtension: "py") else {
                throw FanCollectionError.missingCollector
            }
            input = try Data(contentsOf: script)
        }
        do {
            let data = try await RemoteUsageCommand.run(
                executable: URL(fileURLWithPath: "/usr/bin/ssh"),
                arguments: CPUCollector.arguments(for: target, command: command), input: input,
                timeout: 12, maximumOutputBytes: 64 * 1_024
            )
            return try alias == "macserver" ? FanSnapshot.decode(data) : FanSnapshot.decodeWindows(data)
        } catch CodexRemoteUsageSyncError.cancelled {
            throw CancellationError()
        } catch CodexRemoteUsageSyncError.timedOut {
            throw FanCollectionError.timedOut
        }
    }
}
