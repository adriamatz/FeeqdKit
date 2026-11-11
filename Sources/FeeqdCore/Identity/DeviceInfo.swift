import Foundation

/// The `X-Feeqd-Device-Info` header: model, OS, app version, build, SDK and locale.
///
/// It is what lands next to a bug report in the dashboard. The server ignores anything over
/// 512 bytes, so the least useful fields go first if it ever gets that long.
package enum DeviceInfo {
    package static func headerValue(sdkVersion: String, appVersion: String? = nil) -> String? {
        let bundle = Bundle.main.infoDictionary
        var info: [String: String] = [
            "model": modelIdentifier(),
            "os": osVersion(),
            "sdk": sdkVersion,
            "locale": Locale.current.identifier,
        ]
        if let app = appVersion ?? (bundle?["CFBundleShortVersionString"] as? String) { info["app"] = app }
        if let build = bundle?["CFBundleVersion"] as? String { info["build"] = build }

        for dropped in [nil, "locale", "build"] as [String?] {
            if let dropped { info[dropped] = nil }
            if let data = try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]), data.count <= 512 {
                return String(data: data, encoding: .utf8)
            }
        }
        return nil
    }

    /// The same fields as the header, for a chat message's context: the dashboard reads the
    /// context, not the header, so this is what puts the model and OS beside a conversation.
    /// No size cap here: the context has no 512-byte limit.
    package static func contextValue(sdkVersion: String, appVersion: String? = nil) -> [String: String] {
        let bundle = Bundle.main.infoDictionary
        var info: [String: String] = [
            "model": modelIdentifier(),
            "os": osVersion(),
            "sdk": sdkVersion,
            "locale": Locale.current.identifier,
        ]
        // The language the SDK's texts show in, which the locale is not when the app itself is
        // not translated: the dashboard writes a review request in it.
        if let language = Locale.preferredLanguages.first { info["language"] = language }
        if let app = appVersion ?? (bundle?["CFBundleShortVersionString"] as? String) { info["app"] = app }
        if let build = bundle?["CFBundleVersion"] as? String { info["build"] = build }
        return info
    }

    /// What goes with the launch request: the app and SDK versions, nothing about the device.
    ///
    /// The backend records a device once an hour, from whichever request comes first, and that
    /// is the launch. Without this the dashboard's app-version spread would stay empty for the
    /// hour; with the full header, model and OS would leave the device on every launch.
    package static func launchHeaderValue(sdkVersion: String, appVersion: String? = nil) -> String? {
        var info = ["sdk": sdkVersion]
        if let app = appVersion ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) { info["app"] = app }
        guard let data = try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// `iPhone16,1`, not "iPhone": the identifier is what tells two models apart in a bug.
    package static func modelIdentifier() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    package static func osVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}
