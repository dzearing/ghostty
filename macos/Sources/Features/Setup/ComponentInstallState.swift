// macos/Sources/Features/Setup/ComponentInstallState.swift
import Foundation

/// Install state of a single managed artifact, and (aggregated across an agent's
/// components) of a whole runtime integration. One shared type: the component and
/// runtime levels use the same three-state vocabulary, so a second identical enum
/// only invited them to drift apart.
enum ComponentInstallState: Equatable, Sendable {
    case notInstalled
    case installed
    case outdated
}

/// The aggregate state of a runtime's integration is the same three-state value
/// as a single component; kept as an alias so call sites read intentionally.
typealias RuntimeIntegrationState = ComponentInstallState
