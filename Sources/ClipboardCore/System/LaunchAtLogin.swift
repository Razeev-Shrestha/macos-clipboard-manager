import Foundation
import ServiceManagement

public enum LaunchAtLoginStatus: Equatable, Sendable {
    case unknown
    case disabled
    case enabled
    case requiresApproval
    case unavailable
    case failed
}

/// Small native seam around SMAppService.mainApp. Tests inject this value and never
/// register a real login item.
@MainActor
public struct LaunchAtLoginNativeBoundary {
    public var status: () -> LaunchAtLoginStatus
    public var register: () throws -> Void
    public var unregister: () throws -> Void

    public init(
        status: @escaping () -> LaunchAtLoginStatus,
        register: @escaping () throws -> Void,
        unregister: @escaping () throws -> Void
    ) {
        self.status = status
        self.register = register
        self.unregister = unregister
    }

    public static let live = LaunchAtLoginNativeBoundary(
        status: {
            switch SMAppService.mainApp.status {
            case .notRegistered:
                .disabled
            case .enabled:
                .enabled
            case .requiresApproval:
                .requiresApproval
            case .notFound:
                .unavailable
            @unknown default:
                .unknown
            }
        },
        register: {
            try SMAppService.mainApp.register()
        },
        unregister: {
            try SMAppService.mainApp.unregister()
        }
    )
}

@MainActor
public final class LaunchAtLoginController: ObservableObject {
    @Published public private(set) var status: LaunchAtLoginStatus = .unknown

    private let native: LaunchAtLoginNativeBoundary

    public init(native: LaunchAtLoginNativeBoundary = .live) {
        self.native = native
        status = native.status()
    }

    @discardableResult
    public func refresh() -> LaunchAtLoginStatus {
        status = native.status()
        return status
    }

    @discardableResult
    public func setEnabled(_ enabled: Bool) -> LaunchAtLoginStatus {
        // The published value can become stale when the user changes Login Items
        // in System Settings or another process changes the native registration.
        // Observe the native state before deciding that this request is already
        // satisfied.
        status = native.status()
        if enabled && (status == .enabled || status == .requiresApproval) {
            return status
        }
        if !enabled, status == .disabled {
            return status
        }

        do {
            if enabled {
                try native.register()
            } else {
                try native.unregister()
            }
        } catch {
            let observed = native.status()
            if enabled {
                status = switch observed {
                case .enabled, .requiresApproval, .unavailable:
                    observed
                default:
                    .failed
                }
            } else {
                status = switch observed {
                case .disabled, .unavailable:
                    observed
                default:
                    .failed
                }
            }
            return status
        }
        return refresh()
    }
}
