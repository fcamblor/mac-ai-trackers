import Foundation

/// Discovers child components of an incident.io status-page group.
///
/// incident.io exposes no public unauthenticated JSON endpoint for the
/// component hierarchy, so we parse the Next.js RSC payload embedded in the
/// page HTML. The payload arrives as `self.__next_f.push([1, "..."])` calls
/// whose second argument is a JSON-escaped chunk; concatenating those chunks
/// (and unescaping `\"`) yields a stream that contains plain
/// `"id":"...","name":"...","group_id":"..."` objects we can mine with a
/// regex.
///
/// Fails loud (throws) if the page yields zero matches — the page schema may
/// have changed and we want the test suite (or the manual refresh button) to
/// surface that immediately rather than silently masking it with an empty
/// list.
public protocol IncidentIOComponentsDiscovery: Sendable {
    func discover(host: String, groupRootID: StatusComponentID) async throws -> [StatusComponent]
}

public enum IncidentIOComponentsDiscoveryError: Error, CustomStringConvertible {
    case invalidURL(rawValue: String)
    case networkError(underlying: Error, url: String)
    case unexpectedResponse(statusCode: Int, url: String)
    case noComponentsFound(url: String, groupRootID: String)

    public var description: String {
        switch self {
        case let .invalidURL(raw):
            "Invalid status page URL: \(raw)"
        case let .networkError(err, url):
            "Status page network error for \(url): \(err)"
        case let .unexpectedResponse(code, url):
            "Status page returned HTTP \(code) for \(url)"
        case let .noComponentsFound(url, groupRootID):
            "No incident.io components matched group_id=\(groupRootID) on \(url) — page schema may have changed"
        }
    }
}

public actor IncidentIOPageComponentsDiscovery: IncidentIOComponentsDiscovery {
    private let logger: FileLogger
    private let session: URLSession
    private let requestTimeoutSeconds: TimeInterval

    public init(
        logger: FileLogger = Loggers.codex,
        session: URLSession = .shared,
        requestTimeoutSeconds: TimeInterval = 10.0
    ) {
        self.logger = logger
        self.session = session
        self.requestTimeoutSeconds = requestTimeoutSeconds
    }

    public func discover(
        host: String,
        groupRootID: StatusComponentID
    ) async throws -> [StatusComponent] {
        let urlString = "https://\(host)/"
        guard let url = URL(string: urlString) else {
            throw IncidentIOComponentsDiscoveryError.invalidURL(rawValue: urlString)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeoutSeconds
        request.setValue("text/html", forHTTPHeaderField: "Accept")

        logger.log(.debug, "Discovering incident.io components from \(urlString)")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw IncidentIOComponentsDiscoveryError.networkError(underlying: error, url: urlString)
        }

        let httpCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard httpCode == 200 else {
            throw IncidentIOComponentsDiscoveryError.unexpectedResponse(
                statusCode: httpCode, url: urlString
            )
        }

        let html = String(decoding: data, as: UTF8.self)
        let components = Self.extractComponents(fromHTML: html, groupRootID: groupRootID)

        guard !components.isEmpty else {
            throw IncidentIOComponentsDiscoveryError.noComponentsFound(
                url: urlString,
                groupRootID: groupRootID.rawValue
            )
        }

        logger.log(
            .info,
            "Discovered \(components.count) incident.io component(s) under group \(groupRootID.rawValue)"
        )
        return components
    }

    /// Public for tests: extracts components from a raw page HTML string by
    /// matching the JSON-shaped triples embedded in the Next.js RSC payload.
    public static func extractComponents(
        fromHTML html: String,
        groupRootID: StatusComponentID
    ) -> [StatusComponent] {
        // RSC chunks live inside JS string literals where every `"` is escaped
        // as `\"`. Unescape once so a single regex covers both the rare
        // unescaped occurrences and the normal escaped ones.
        let unescaped = html.replacingOccurrences(of: "\\\"", with: "\"")
        return extractComponents(fromUnescapedPayload: unescaped, groupRootID: groupRootID)
    }

    /// Same as `extractComponents(fromHTML:)` but takes a payload whose JSON
    /// string-escaping has already been undone — useful for tests that hand in
    /// a plain JSON fixture rather than a full HTML page.
    public static func extractComponents(
        fromUnescapedPayload payload: String,
        groupRootID: StatusComponentID
    ) -> [StatusComponent] {
        // Strategy: incident.io serializes a group's children as a nested
        // `components` array on the group object itself, e.g.
        // `{"components":[{"component_id":"01...","name":"Codex Web",…},…],
        //   …,"id":"<group_root_id>","name":"Codex"}`.
        // So we:
        //   1. locate the enclosing object that carries `"id":"<groupRootID>"`,
        //   2. find its `"components":[…]` array,
        //   3. enumerate each top-level child object inside that array.
        //
        // No depth-aware string tracking is needed — after unescape, value
        // strings never contain a literal `{` or `}` in the incident.io
        // shape we're targeting.
        guard let groupObject = enclosingObject(
            containing: "\"id\":\"\(groupRootID.rawValue)\"",
            in: payload
        ) else { return [] }
        guard let componentsArray = extractArray(named: "components", in: groupObject) else {
            return []
        }
        var seenIDs = Set<String>()
        var components: [StatusComponent] = []
        for slice in enumerateTopLevelObjects(in: componentsArray) {
            guard let id = firstCapture(
                in: slice,
                pattern: #"\"component_id\"\s*:\s*\"([0-9A-HJKMNP-TV-Z]{26})\""#
            ) else { continue }
            guard let name = firstCapture(
                in: slice,
                pattern: #"\"name\"\s*:\s*\"([^\"\\]{1,200})\""#
            ) else { continue }
            guard seenIDs.insert(id).inserted else { continue }
            components.append(StatusComponent(
                id: StatusComponentID(rawValue: id),
                name: name,
                groupID: groupRootID
            ))
        }
        return components
    }

    /// Returns the smallest `{…}` substring that wholly contains `needle`,
    /// walking outward from the needle's first occurrence and matching
    /// braces. `nil` if no such enclosure exists.
    private static func enclosingObject(containing needle: String, in payload: String) -> String? {
        guard let needleRange = payload.range(of: needle) else { return nil }
        guard needleRange.lowerBound > payload.startIndex else { return nil }

        var depth = 0
        var openIndex: String.Index?
        var index = payload.index(before: needleRange.lowerBound)
        while index >= payload.startIndex {
            let ch = payload[index]
            if ch == "}" {
                depth += 1
            } else if ch == "{" {
                if depth == 0 {
                    openIndex = index
                    break
                }
                depth -= 1
            }
            if index == payload.startIndex { break }
            index = payload.index(before: index)
        }
        guard let openIndex else { return nil }

        depth = 0
        var forward = needleRange.upperBound
        while forward < payload.endIndex {
            let ch = payload[forward]
            if ch == "{" {
                depth += 1
            } else if ch == "}" {
                if depth == 0 {
                    let endExclusive = payload.index(after: forward)
                    return String(payload[openIndex..<endExclusive])
                }
                depth -= 1
            }
            forward = payload.index(after: forward)
        }
        return nil
    }

    /// Extracts the substring inside `"<name>":[ … ]` (the brackets included).
    private static func extractArray(named field: String, in text: String) -> String? {
        guard let opening = text.range(of: "\"\(field)\":[")
            ?? text.range(of: "\"\(field)\": [")
        else { return nil }
        var depth = 0
        var index = text.index(before: opening.upperBound)
        while index < text.endIndex {
            let ch = text[index]
            if ch == "[" {
                depth += 1
            } else if ch == "]" {
                depth -= 1
                if depth == 0 {
                    let endExclusive = text.index(after: index)
                    return String(text[opening.upperBound..<endExclusive])
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func enumerateTopLevelObjects(in payload: String) -> [String] {
        // The component objects we mine are flat — values never contain
        // `{` or `}` — so plain brace depth counting is sufficient.
        var depth = 0
        var sliceStart: String.Index?
        var slices: [String] = []
        var index = payload.startIndex
        while index < payload.endIndex {
            let ch = payload[index]
            if ch == "{" {
                if depth == 0 {
                    sliceStart = index
                }
                depth += 1
            } else if ch == "}" {
                if depth > 0 {
                    depth -= 1
                    if depth == 0, let start = sliceStart {
                        let endInclusive = payload.index(after: index)
                        slices.append(String(payload[start..<endInclusive]))
                        sliceStart = nil
                    }
                }
            }
            index = payload.index(after: index)
        }
        return slices
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges == 2 else { return nil }
        return ns.substring(with: match.range(at: 1))
    }
}
