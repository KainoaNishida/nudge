import AppKit
import Foundation

enum AppleMessagesLink {
    static func url(threadExternalId: String) -> URL? {
        let parts = threadExternalId.split(separator: ";", omittingEmptySubsequences: false)
        guard parts.count == 3,
              ["imessage", "sms", "rcs", "any"].contains(parts[0].lowercased()),
              !parts[2].isEmpty,
              parts[2].rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil
        else {
            return nil
        }

        // Encode the identifier as data, so characters in an email address cannot
        // introduce another recipient, a message body, or other URL parameters.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let identifier = String(parts[2]).addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }

        switch parts[1] {
        case "-":
            return URL(string: "sms:\(identifier)")
        case "+":
            // Messages on macOS uses this route for an existing group chat's
            // chatIdentifier (the final part of its GUID). It is undocumented.
            return URL(string: "sms://open?groupid=\(identifier)")
        default:
            return nil
        }
    }

    @MainActor
    static func open(_ url: URL) async throws {
        let workspace = NSWorkspace.shared
        guard let applicationURL = workspace.urlForApplication(withBundleIdentifier: "com.apple.MobileSMS")
            ?? workspace.urlForApplication(withBundleIdentifier: "com.apple.iChat") else {
            throw OpenError.messagesUnavailable
        }
        _ = try await workspace.open(
            [url],
            withApplicationAt: applicationURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    private enum OpenError: LocalizedError {
        case messagesUnavailable

        var errorDescription: String? {
            "Messages could not be found on this Mac."
        }
    }
}
