import Foundation

/// A Model Context Protocol server, so Claude can run Prism: read the cues,
/// put one up, change colours, levels and fades. It speaks the protocol's
/// Streamable HTTP transport in its plainest form, the way Screens does: each
/// POST is one JSON-RPC message, answered with one JSON reply, nothing
/// streamed. `MCPHost` puts it on the network behind a key.
public struct MCPTool: Sendable {
    public var name: String
    public var title: String
    public var description: String
    public var inputSchema: JSONValue
    public var readOnly: Bool
    public var handler: @MainActor @Sendable (JSONValue) async throws -> MCPToolResult

    public init(
        name: String, title: String, description: String, inputSchema: JSONValue, readOnly: Bool = false,
        handler: @escaping @MainActor @Sendable (JSONValue) async throws -> MCPToolResult
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.readOnly = readOnly
        self.handler = handler
    }
}

/// What a tool hands back: text for Claude to read, and the same thing as
/// structured JSON when there is some.
public struct MCPToolResult: Sendable {
    public var text: String
    public var structured: JSONValue?
    public var isError: Bool

    public init(text: String, structured: JSONValue? = nil, isError: Bool = false) {
        self.text = text
        self.structured = structured
        self.isError = isError
    }

    /// The value as pretty JSON with snake_case keys, after an optional
    /// one-line summary.
    public static func json(_ value: some Encodable, summary: String? = nil) -> MCPToolResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        let text = String(decoding: data, as: UTF8.self)
        let structured = try? JSONDecoder().decode(JSONValue.self, from: data)
        let objectLike: JSONValue? = if case .object = structured { structured } else { nil }
        return MCPToolResult(text: summary.map { $0 + "\n\n" + text } ?? text, structured: objectLike)
    }
}

/// A tool's input was wrong in a way Claude can fix and try again.
public struct MCPToolError: Error, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

public struct MCPServer: Sendable {
    /// Newest first. The client's version is used when it is one of these.
    public static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    public var version: String
    public var instructions: String
    public var tools: [MCPTool]

    public init(version: String, instructions: String, tools: [MCPTool]) {
        self.version = version
        self.instructions = instructions
        self.tools = tools
    }

    /// One POSTed message in, the HTTP status and body to answer with. A
    /// notification or a reply from the client gets 202 and no body.
    public func handle(body: Data) async -> (status: Int, body: Data) {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: body),
              case .object(let fields) = message else {
            return reply(error: -32700, "Parse error", id: .null)
        }
        guard case .string(let method)? = fields["method"] else {
            if fields["result"] != nil || fields["error"] != nil { return (202, Data()) }
            return reply(error: -32600, "Invalid request", id: fields["id"] ?? .null)
        }
        guard let id = fields["id"], id != .null else { return (202, Data()) }
        let params = fields["params"] ?? .object([:])
        switch method {
        case "initialize":
            let asked = params["protocolVersion"]?.stringValue ?? ""
            let protocolVersion = Self.protocolVersions.contains(asked) ? asked : Self.protocolVersions[0]
            return reply(result: [
                "protocolVersion": .string(protocolVersion),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "prism", "title": "Prism", "version": .string(version)],
                "instructions": .string(instructions),
            ], id: id)
        case "ping":
            return reply(result: [:], id: id)
        case "tools/list":
            let listed = tools.map { tool -> JSONValue in
                [
                    "name": .string(tool.name),
                    "title": .string(tool.title),
                    "description": .string(tool.description),
                    "inputSchema": tool.inputSchema,
                    "annotations": [
                        "title": .string(tool.title),
                        "readOnlyHint": .bool(tool.readOnly),
                        "destructiveHint": .bool(tool.name == "delete_cue"),
                        "openWorldHint": false,
                    ],
                ]
            }
            return reply(result: ["tools": .array(listed)], id: id)
        case "tools/call":
            guard let toolName = params["name"]?.stringValue,
                  let tool = tools.first(where: { $0.name == toolName }) else {
                return reply(error: -32602, "Unknown tool: \(params["name"]?.stringValue ?? "")", id: id)
            }
            let arguments = params["arguments"] ?? .object([:])
            do {
                return reply(result: Self.content(try await tool.handler(arguments)), id: id)
            } catch let error as MCPToolError {
                return reply(result: Self.content(MCPToolResult(text: error.message, isError: true)), id: id)
            } catch {
                return reply(result: Self.content(MCPToolResult(text: "\(error)", isError: true)), id: id)
            }
        case "resources/list":
            return reply(result: ["resources": []], id: id)
        case "prompts/list":
            return reply(result: ["prompts": []], id: id)
        default:
            return reply(error: -32601, "Method not found: \(method)", id: id)
        }
    }

    static func content(_ result: MCPToolResult) -> JSONValue {
        var out: [String: JSONValue] = [
            "content": [["type": "text", "text": .string(result.text)]],
            "isError": .bool(result.isError),
        ]
        if let structured = result.structured { out["structuredContent"] = structured }
        return .object(out)
    }

    private func reply(result: JSONValue, id: JSONValue) -> (status: Int, body: Data) {
        (200, JSONValue.object(["jsonrpc": "2.0", "id": id, "result": result]).encoded())
    }

    private func reply(error code: Int, _ message: String, id: JSONValue) -> (status: Int, body: Data) {
        (200, JSONValue.object([
            "jsonrpc": "2.0", "id": id,
            "error": ["code": .integer(code), "message": .string(message)],
        ]).encoded())
    }
}
