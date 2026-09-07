import Foundation

/// Only explicit Desktop-client imports; errors never echo credential contents.
public enum GoogleDesktopClientFile {
    public static func parse(_ data: Data) throws -> GoogleOAuthConfiguration {
        guard data.count <= 65_536,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], root["web"] == nil,
              let client = root["installed"] as? [String: Any],
              let id = client["client_id"] as? String, id.hasSuffix(".apps.googleusercontent.com"),
              !id.contains(where: \.isWhitespace),
              let secret = client["client_secret"] as? String, !secret.isEmpty else { throw GoogleServiceError.invalidConfiguration }
        return GoogleOAuthConfiguration(clientID: id, clientSecret: secret)
    }
    public static func folderID(_ input: String) throws -> String {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ","))
        if DriveAPI.validID(text) { return text }
        guard let url = URL(string: text), url.scheme == "https", url.host == "drive.google.com", url.user == nil, url.password == nil,
              let index = url.pathComponents.firstIndex(of: "folders"), index + 2 == url.pathComponents.count,
              DriveAPI.validID(url.pathComponents[index + 1]) else { throw GoogleServiceError.invalidConfiguration }
        return url.pathComponents[index + 1]
    }
}
