// macos/Sources/Features/Setup/ComponentInstallState.swift
import Foundation

enum ComponentInstallState: Equatable, Sendable {
    case notInstalled
    case installed
    case outdated
}

enum RuntimeIntegrationState: Equatable, Sendable {
    case notInstalled
    case installed
    case outdated
}
