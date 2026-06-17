import Foundation
import Observation
import UIKit

// MARK: - MapAppService

/// Detects installed map apps, opens them, and manages the default-app preference.
///
/// `MapAppService` is designed for full testability: all interactions with
/// `UIApplication` are abstracted behind injected closures so unit tests never touch the
/// real application singleton.
///
/// ## Usage
/// ```swift
/// let service = MapAppService()               // production
/// let mock    = MapAppService(
///     canOpen: { _ in true },
///     opener:  { url in capturedURLs.append(url) }
/// )
/// ```
@MainActor @Observable public final class MapAppService {
    // MARK: - Injected capabilities

    private let roster: [MapApp]
    private let canOpen: (URL) -> Bool
    private let opener: (URL) -> Void

    // MARK: - Init

    /// Creates a `MapAppService`.
    ///
    /// - Parameters:
    ///   - roster: The list of candidate map apps. Defaults to `MapApp.platformRoster()`,
    ///     which adds Google Maps in the browser only when running as an iOS app on macOS.
    ///   - canOpen: Closure that returns `true` when the given URL scheme is registered
    ///     on this device. Defaults to `UIApplication.shared.canOpenURL(_:)`.
    ///   - opener: Closure that opens the URL (launches the map app). Defaults to
    ///     `UIApplication.shared.open(_:)`.
    public init(
        roster: [MapApp] = MapApp.platformRoster(),
        canOpen: @escaping (URL) -> Bool = { UIApplication.shared.canOpenURL($0) },
        opener: @escaping (URL) -> Void = { UIApplication.shared.open($0) }
    ) {
        self.roster = roster
        self.canOpen = canOpen
        self.opener = opener
    }

    // MARK: - Detection

    /// Returns all map apps that are present on this device.
    ///
    /// An app is considered "installed" when either:
    /// - its `alwaysAvailable` flag is `true` (Apple Maps or browser-based destinations), or
    /// - its `urlScheme` can be opened according to the injected `canOpen` closure.
    ///
    /// The result preserves roster order.
    ///
    /// - Returns: A filtered list of `MapApp` values, always containing at least Apple Maps.
    public func installedApps() -> [MapApp] {
        roster.filter { app in
            if app.alwaysAvailable { return true }
            guard let scheme = app.urlScheme,
                  let probeURL = URL(string: "\(scheme)://") else { return false }
            return canOpen(probeURL)
        }
    }

    // MARK: - Available (installed ∩ enabled)

    /// Returns installed apps intersected with the caller's enabled set.
    ///
    /// When `enabledIDs` is empty, all installed apps are treated as enabled — this is
    /// the sensible default before the user has visited Settings and customised the list.
    ///
    /// - Parameter enabledIDs: The `[String]` stored in `AppSettings.enabledMapAppIDs`.
    /// - Returns: Ordered subset of installed apps.
    public func availableApps(enabledIDs: [String]) -> [MapApp] {
        let installed = installedApps()
        guard !enabledIDs.isEmpty else { return installed }
        let enabledSet = Set(enabledIDs)
        return installed.filter { enabledSet.contains($0.id) }
    }

    // MARK: - Open

    /// Builds a deep-link URL for `app` at the given coordinate and calls the opener.
    ///
    /// - Parameters:
    ///   - app: The target map app.
    ///   - latitude: WGS-84 latitude in decimal degrees.
    ///   - longitude: WGS-84 longitude in decimal degrees.
    ///   - name: Human-readable pin label; URL-encoded by the app's builder.
    /// - Returns: `true` when a URL was built and the opener was called; `false` when
    ///   the app's URL builder returns `nil` (e.g. invalid coordinates).
    @discardableResult
    public func open(
        _ app: MapApp,
        latitude: Double,
        longitude: Double,
        name: String
    ) -> Bool {
        guard let url = app.makeURL(latitude, longitude, name) else { return false }
        opener(url)
        return true
    }

    // MARK: - Default resolution

    /// Resolves the stored default map app, re-validating that it is still installed and enabled.
    ///
    /// Returns the default app when all three conditions hold:
    /// 1. `id` is non-nil.
    /// 2. The app with that `id` is currently installed (i.e. `canOpenURL` passes).
    /// 3. The app appears in `availableApps(enabledIDs:)` (it is enabled).
    ///
    /// Returns `nil` in every other case — the caller should show the picker sheet and,
    /// when appropriate, clear the stored default in `AppSettings`.
    ///
    /// - Parameters:
    ///   - id: The value of `AppSettings.defaultMapAppID`.
    ///   - enabledIDs: The value of `AppSettings.enabledMapAppIDs`.
    /// - Returns: The resolved `MapApp`, or `nil`.
    public func resolveDefault(id: String?, enabledIDs: [String]) -> MapApp? {
        guard let id else { return nil }
        let available = availableApps(enabledIDs: enabledIDs)
        return available.first { $0.id == id }
    }
}
