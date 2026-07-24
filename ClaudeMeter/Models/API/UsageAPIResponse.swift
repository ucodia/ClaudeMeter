//
//  UsageAPIResponse.swift
//  ClaudeMeter
//
//  Created by Edd on 2025-11-14.
//

import Foundation

/// API response for usage data
struct UsageAPIResponse: Codable {
    let fiveHour: UsageLimitResponse
    let sevenDay: UsageLimitResponse
    let sevenDaySonnet: UsageLimitResponse?
    let sevenDayFable: UsageLimitResponse?
    let limits: [ScopedLimitResponse]?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayFable = "seven_day_fable"
        case limits
    }
}

/// Entry in the `limits` array. Migrated accounts report per-model weekly
/// quotas here (`kind: "weekly_scoped"`, model display name in `scope`)
/// instead of dedicated `seven_day_*` fields. All fields are optional so an
/// unfamiliar entry never fails the whole decode.
struct ScopedLimitResponse: Codable {
    let kind: String?
    let percent: Double?
    let resetsAt: String?
    let scope: Scope?

    enum CodingKeys: String, CodingKey {
        case kind
        case percent
        case resetsAt = "resets_at"
        case scope
    }

    struct Scope: Codable {
        let model: Model?

        struct Model: Codable {
            let displayName: String?

            enum CodingKeys: String, CodingKey {
                case displayName = "display_name"
            }
        }
    }
}

/// Individual usage limit response from API
struct UsageLimitResponse: Codable {
    let utilization: Double // Percentage 0-100
    let resetsAt: String? // ISO8601 string, can be null

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

/// Mapping error for API response conversion
enum MappingError: LocalizedError {
    case invalidDateFormat
    case missingCriticalField(field: String)

    var errorDescription: String? {
        switch self {
        case .invalidDateFormat:
            return "Server returned invalid date format"
        case .missingCriticalField(let field):
            return "Server response missing critical field: \(field)"
        }
    }
}

/// Extension to map API response to domain model
extension UsageAPIResponse {
    func toDomain() throws -> UsageData {
        let iso8601Formatter = ISO8601DateFormatter()
        iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let sessionResetDate = try parseResetDate(
            from: fiveHour.resetsAt,
            field: "fiveHour.resetsAt",
            formatter: iso8601Formatter,
            fallback: Constants.Pacing.sessionWindow
        )
        let weeklyResetDate = try parseResetDate(
            from: sevenDay.resetsAt,
            field: "sevenDay.resetsAt",
            formatter: iso8601Formatter,
            fallback: Constants.Pacing.weeklyWindow
        )

        // Handle optional sonnet usage
        let sonnetLimit: UsageLimit? = try sevenDaySonnet.flatMap { sonnet -> UsageLimit? in
            let sonnetResetDate = try parseResetDate(
                from: sonnet.resetsAt,
                field: "sevenDaySonnet.resetsAt",
                formatter: iso8601Formatter,
                fallback: Constants.Pacing.weeklyWindow
            )
            return UsageLimit(
                utilization: sonnet.utilization,
                resetAt: sonnetResetDate
            )
        }

        // Fable quota lives in a dedicated field on older accounts, but in the
        // `limits` array (`weekly_scoped` entry) on migrated ones
        let fableResponse = sevenDayFable ?? weeklyScopedResponse(modelNamed: "Fable")
        let fableLimit: UsageLimit? = try fableResponse.flatMap { fable -> UsageLimit? in
            let fableResetDate = try parseResetDate(
                from: fable.resetsAt,
                field: "sevenDayFable.resetsAt",
                formatter: iso8601Formatter,
                fallback: Constants.Pacing.weeklyWindow
            )
            return UsageLimit(
                utilization: fable.utilization,
                resetAt: fableResetDate
            )
        }

        return UsageData(
            sessionUsage: UsageLimit(
                utilization: fiveHour.utilization,
                resetAt: sessionResetDate
            ),
            weeklyUsage: UsageLimit(
                utilization: sevenDay.utilization,
                resetAt: weeklyResetDate
            ),
            sonnetUsage: sonnetLimit,
            fableUsage: fableLimit,
            lastUpdated: Date()
        )
    }

    /// Adapts a `weekly_scoped` entry from `limits` into the same shape as a
    /// dedicated `seven_day_*` field (the array reports `percent` rather than
    /// `utilization`).
    private func weeklyScopedResponse(modelNamed name: String) -> UsageLimitResponse? {
        guard let match = limits?.first(where: {
            $0.kind == "weekly_scoped" &&
            $0.scope?.model?.displayName?.caseInsensitiveCompare(name) == .orderedSame
        }), let percent = match.percent else {
            return nil
        }
        return UsageLimitResponse(utilization: percent, resetsAt: match.resetsAt)
    }

    private func parseResetDate(
        from rawValue: String?,
        field: String,
        formatter: ISO8601DateFormatter,
        fallback: TimeInterval
    ) throws -> Date {
        guard let rawValue else {
            return Date().addingTimeInterval(fallback)
        }
        guard let date = formatter.date(from: rawValue) else {
            throw MappingError.missingCriticalField(field: field)
        }
        return date
    }
}
