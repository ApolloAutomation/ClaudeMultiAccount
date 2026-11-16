import Foundation

/// Pure transforms of `com.apple.dock` `persistent-apps`.
public enum DockPlist {
    public static func tile(appURL: URL, label: String, bundleID: String) -> [String: Any] {
        [
            "tile-type": "file-tile",
            "tile-data": [
                "file-data": ["_CFURLString": appURL.absoluteString, "_CFURLStringType": 15] as [String: Any],
                "file-label": label,
                "bundle-identifier": bundleID,
                "file-type": 41,
            ] as [String: Any],
        ]
    }

    public static func bundleID(of item: Any) -> String? {
        ((item as? [String: Any])?["tile-data"] as? [String: Any])?["bundle-identifier"] as? String
    }

    public static func urlString(of item: Any) -> String? {
        (((item as? [String: Any])?["tile-data"] as? [String: Any])?["file-data"] as? [String: Any])?["_CFURLString"] as? String
    }

    public static func contains(_ apps: [Any], bundleID: String) -> Bool {
        apps.contains { Self.bundleID(of: $0)?.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    /// Appends a tile unless one with the bundle id exists; an existing tile is updated in place (url/label).
    public static func adding(_ apps: [Any], appURL: URL, label: String, bundleID: String) -> [Any] {
        var out = apps
        if let i = out.firstIndex(where: { Self.bundleID(of: $0)?.caseInsensitiveCompare(bundleID) == .orderedSame }) {
            if var item = out[i] as? [String: Any], var td = item["tile-data"] as? [String: Any] {
                var fd = td["file-data"] as? [String: Any] ?? [:]
                fd["_CFURLString"] = appURL.absoluteString
                fd["_CFURLStringType"] = 15
                td["file-data"] = fd
                td["file-label"] = label
                item["tile-data"] = td
                out[i] = item
            }
            return out
        }
        out.append(tile(appURL: appURL, label: label, bundleID: bundleID))
        return out
    }

    public static func removing(_ apps: [Any], bundleID: String) -> [Any] {
        apps.filter { Self.bundleID(of: $0)?.caseInsensitiveCompare(bundleID) != .orderedSame }
    }
}
