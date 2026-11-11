import CoreGraphics
import Foundation
import ImageIO

/// Screens' Local API (Settings › Integrations › Remote & API in Screens),
/// for the one thing the lights need from it: the live slide's background,
/// so a song's SlimPARs can match it.
public struct ScreensAPI: Sendable, Equatable {
    public static let defaultPort = 6980

    /// Screens' Mac: "127.0.0.1" when it's this one, otherwise its address
    /// or Bonjour name ("booth-mac.local").
    public var host: String
    public var port: Int
    /// An access key from Screens' Manage Keys; Watch is enough.
    public var key: String

    public init(host: String, port: Int = defaultPort, key: String) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
        self.key = key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public enum Failure: Error, Equatable, Sendable {
        case notSetUp, unreachable, refused, noBackground, unreadable

        /// What Settings says about it.
        public var message: String {
            switch self {
            case .notSetUp: "Enter the Screens Mac and an access key."
            case .unreachable: "Couldn't reach Screens. Check its address, and that Remote & API is on in Screens."
            case .refused: "Screens refused the access key."
            case .noBackground: "Screens has no background up right now."
            case .unreadable: "Screens sent something that isn't a picture."
            }
        }
    }

    public var isSetUp: Bool { url("/") != nil }

    /// nil until a host and key are set.
    public func url(_ path: String) -> URL? {
        guard !host.isEmpty, !key.isEmpty, (1...65535).contains(port) else { return nil }
        // An IPv6 literal needs brackets in a URL.
        let hostPart = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return URL(string: "http://\(hostPart):\(port)\(path)")
    }

    private func get(_ path: String, session: URLSession) async -> Result<Data, Failure> {
        guard let url = url(path) else { return .failure(.notSetUp) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else { return .failure(.unreachable) }
        switch http.statusCode {
        case 200: return .success(data)
        case 401, 403: return .failure(.refused)
        case 404: return .failure(.noBackground)
        default: return .failure(.unreachable)
        }
    }

    /// A small JPEG of the live background: a video's poster frame, or the picture.
    public func background(session: URLSession = .shared) async -> Result<CGImage, Failure> {
        await backgroundJPEG(session: session).flatMap(Self.image(from:))
    }

    /// The background's JPEG as Screens sends it, so a caller can tell a
    /// new background from the same one asked for again.
    public func backgroundJPEG(session: URLSession = .shared) async -> Result<Data, Failure> {
        await get("/v1/show/frames/background", session: session)
    }

    public static func image(from data: Data) -> Result<CGImage, Failure> {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return .failure(.unreadable) }
        return .success(image)
    }

    /// What's live in Screens, as a short string that changes when the
    /// background can: the live slide and the media on each layer. It is a
    /// small JSON read, cheap enough to ask every second, where rendering the
    /// background is not.
    public func liveSignature(session: URLSession = .shared) async -> Result<String, Failure> {
        await get("/v1/status", session: session).flatMap { data in
            guard let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure(.unreadable)
            }
            return .success(Self.signature(of: status))
        }
    }

    static func signature(of status: [String: Any]) -> String {
        let slide = status["liveSlide"] as? [String: Any]
        let slidePart = [slide?["presentationId"], slide?["slideId"]].map { ($0 as? String) ?? "" }.joined(separator: "/")
        let layers = (status["mediaLayers"] as? [String: Any]) ?? [:]
        let mediaPart = layers.keys.sorted().map { key in
            "\(key)=\(((layers[key] as? [String: Any])?["mediaId"] as? String) ?? "")"
        }.joined(separator: ",")
        return slidePart + "|" + mediaPart
    }

    /// Whether Screens answers with this key.
    public func check(session: URLSession = .shared) async -> Result<Void, Failure> {
        await get("/v1/status", session: session).map { _ in () }
    }
}
