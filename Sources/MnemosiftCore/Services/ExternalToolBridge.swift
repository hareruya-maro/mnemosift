import Foundation

/// 外部LLM・AIエージェント連携ブリッジ（CLI コマンド & MCP [Model Context Protocol] stdio サーバー両対応）
@MainActor
public final class ExternalToolBridge {
    private let workspace: AppWorkspaceController

    public init(workspace: AppWorkspaceController) {
        self.workspace = workspace
    }

    /// コマンドライン引数を判定し、CLIまたはMCPモードであれば実行して true を返す（引数なしなら false を返しGUIを起動）
    public static func handleCommandLineIfApplicable(arguments: [String]) async -> Bool {
        guard arguments.count >= 2 else { return false }
        let subcommand = arguments[1]
        // macOS Finder / Xcode 起動時のシステム引数（-NSDocumentRevisionsDebugMode 等）は除外してGUIを起動
        if subcommand.hasPrefix("-NS") || subcommand.hasPrefix("-Apple") || subcommand.hasPrefix("-psn_") {
            return false
        }

        guard let ws = try? AppWorkspaceController(seedDemoDataIfEmpty: false) else {
            FileHandle.standardError.write(Data("Error: Failed to open Mnemosift LocalDatabase.\n".utf8))
            return true
        }
        let bridge = ExternalToolBridge(workspace: ws)
        let output = await bridge.executeCommand(arguments: Array(arguments.dropFirst()))
        if !output.isEmpty {
            FileHandle.standardOutput.write(Data((output + "\n").utf8))
        }
        return true
    }

    public func executeCommand(arguments: [String]) async -> String {
        guard let cmd = arguments.first else { return Self.helpText() }
        let asJSON = arguments.contains("--json")

        switch cmd {
        case "search":
            let queryParts = arguments.dropFirst().filter { !$0.hasPrefix("--") }
            let query = queryParts.joined(separator: " ")
            return runSearchCommand(query: query, asJSON: asJSON)

        case "meetings":
            return runMeetingsCommand(asJSON: asJSON)

        case "documents":
            return runDocumentsCommand(asJSON: asJSON)

        case "vocabulary":
            return runVocabularyCommand(asJSON: asJSON)

        case "mcp":
            await runMCPStdioServerLoop()
            return ""

        case "help", "--help", "-h":
            return Self.helpText()

        default:
            return Self.helpText()
        }
    }

    // MARK: - CLI Implementations

    public func runSearchCommand(query: String, asJSON: Bool) -> String {
        let results = workspace.searchService.search(
            query: query,
            scopeMode: .global,
            limit: 10
        )

        if asJSON {
            struct CLISearchItem: Codable {
                let sourceType: String
                let title: String
                let location: String
                let content: String
                let score: Double
            }
            let payload = results.map {
                CLISearchItem(
                    sourceType: $0.chunk.sourceType.rawValue,
                    title: $0.chunk.title,
                    location: $0.chunk.locationHint,
                    content: $0.chunk.content,
                    score: $0.breakdown.totalScore
                )
            }
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? enc.encode(payload), let str = String(data: data, encoding: .utf8) {
                return str
            }
            return "[]"
        }

        if results.isEmpty {
            return "「\(query)」に一致する資料・議事録は見つかりませんでした。"
        }
        var lines: [String] = ["=== Mnemosift 検索結果 (\(results.count)件): 「\(query)」 ==="]
        for (idx, item) in results.enumerated() {
            lines.append("[\(idx + 1)] [\(item.chunk.sourceType.rawValue)] \(item.chunk.title) (\(item.chunk.locationHint)) - スコア: \(String(format: "%.2f", item.breakdown.totalScore))")
            lines.append("    \(item.chunk.content)")
        }
        return lines.joined(separator: "\n")
    }

    public func runMeetingsCommand(asJSON: Bool) -> String {
        let meetings = workspace.llmService.meetings
        if asJSON {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            enc.dateEncodingStrategy = .iso8601
            if let data = try? enc.encode(meetings), let str = String(data: data, encoding: .utf8) {
                return str
            }
            return "[]"
        }
        if meetings.isEmpty {
            return "保存されている議事録はありません。"
        }
        var lines: [String] = ["=== Mnemosift 議事録一覧 (\(meetings.count)件) ==="]
        for m in meetings {
            lines.append("・\(m.title) (決定事項: \(m.decisions.count)件 / TODO: \(m.actionItems.count)件)")
            for dec in m.decisions {
                lines.append("    [決定] \(dec)")
            }
        }
        return lines.joined(separator: "\n")
    }

    public func runDocumentsCommand(asJSON: Bool) -> String {
        let docs = workspace.documentService.documents
        if asJSON {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? enc.encode(docs), let str = String(data: data, encoding: .utf8) {
                return str
            }
            return "[]"
        }
        var lines: [String] = ["=== Mnemosift 登録資料一覧 (\(docs.count)件) ==="]
        for d in docs {
            lines.append("・\(d.fileName) [\(d.category.rawValue)] - \(d.summary)")
        }
        return lines.joined(separator: "\n")
    }

    public func runVocabularyCommand(asJSON: Bool) -> String {
        let vocabs = workspace.projectService.vocabularies.filter { $0.approvalStatus == .approved }
        if asJSON {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? enc.encode(vocabs), let str = String(data: data, encoding: .utf8) {
                return str
            }
            return "[]"
        }
        var lines: [String] = ["=== Mnemosift 専門用語辞書 (\(vocabs.count)件) ==="]
        for v in vocabs {
            lines.append("・\(v.canonicalForm) (\(v.reading)): \(v.definition)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - MCP (Model Context Protocol) JSON-RPC 2.0 Server Implementation

    public func handleMCPJSONRPCRequest(jsonLine: String) -> String? {
        guard let data = jsonLine.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = obj["method"] as? String else {
            return nil
        }

        let requestId = obj["id"]
        let params = obj["params"] as? [String: Any] ?? [:]

        // Notification (no id) requires no response
        if requestId == nil {
            return nil
        }

        let resultPayload: [String: Any]
        switch method {
        case "initialize":
            resultPayload = [
                "protocolVersion": "2024-11-05",
                "capabilities": [
                    "tools": ["listChanged": false]
                ],
                "serverInfo": [
                    "name": "mnemosift-local-workspace",
                    "version": "0.2.0"
                ]
            ]

        case "tools/list":
            resultPayload = [
                "tools": [
                    [
                        "name": "mnemosift_search",
                        "description": "Mnemosiftのローカル資料・議事録・会議文字起こしをハイブリッド検索（FTS5全文＋Embedding意味検索）します。",
                        "inputSchema": [
                            "type": "object",
                            "properties": [
                                "query": ["type": "string", "description": "検索キーワードまたは質問文"]
                            ],
                            "required": ["query"]
                        ]
                    ],
                    [
                        "name": "mnemosift_list_meetings",
                        "description": "保存されている会議議事録・決定事項・TODOアクションアイテムの一覧を取得します。",
                        "inputSchema": [
                            "type": "object",
                            "properties": [:] as [String: Any]
                        ]
                    ],
                    [
                        "name": "mnemosift_list_documents",
                        "description": "登録されているローカル資料（仕様書・設計書・メモ）の一覧と要約を取得します。",
                        "inputSchema": [
                            "type": "object",
                            "properties": [:] as [String: Any]
                        ]
                    ],
                    [
                        "name": "mnemosift_lookup_vocabulary",
                        "description": "プロジェクトの専門用語辞書と定義を参照します。",
                        "inputSchema": [
                            "type": "object",
                            "properties": [:] as [String: Any]
                        ]
                    ]
                ]
            ]

        case "tools/call":
            let toolName = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            let textResult: String
            switch toolName {
            case "mnemosift_search":
                let q = args["query"] as? String ?? ""
                textResult = runSearchCommand(query: q, asJSON: false)
            case "mnemosift_list_meetings":
                textResult = runMeetingsCommand(asJSON: false)
            case "mnemosift_list_documents":
                textResult = runDocumentsCommand(asJSON: false)
            case "mnemosift_lookup_vocabulary":
                textResult = runVocabularyCommand(asJSON: false)
            default:
                textResult = "Unknown tool: \(toolName)"
            }
            resultPayload = [
                "content": [
                    ["type": "text", "text": textResult]
                ],
                "isError": false
            ]

        default:
            resultPayload = [:]
        }

        let responseObj: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestId as Any,
            "result": resultPayload
        ]
        guard let outData = try? JSONSerialization.data(withJSONObject: responseObj),
              let outStr = String(data: outData, encoding: .utf8) else {
            return nil
        }
        return outStr
    }

    private func runMCPStdioServerLoop() async {
        while let line = readLine() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let reply = handleMCPJSONRPCRequest(jsonLine: trimmed) {
                FileHandle.standardOutput.write(Data((reply + "\n").utf8))
            }
        }
    }

    public static func helpText() -> String {
        """
        Mnemosift — ローカルAIワークスペース & 会議のAIパートナー (GUI / CLI / MCP 両対応)

        使い方:
          Mnemosift                         Mac デスクトップアプリ (GUI) を起動
          Mnemosift search "<クエリ>" [--json] ローカル資料・議事録・発言をハイブリッド検索
          Mnemosift meetings [--json]       議事録・決定事項・TODO一覧を出力
          Mnemosift documents [--json]      登録済みローカル資料一覧を出力
          Mnemosift vocabulary [--json]     承認済み専門用語辞書を出力
          Mnemosift mcp                     MCP (Model Context Protocol) stdio サーバーとして起動
        """
    }

    public static func sampleMCPClientConfigJSON(executablePath: String = "/path/to/Mnemosift") -> String {
        """
        {
          "mcpServers": {
            "mnemosift": {
              "command": "\(executablePath)",
              "args": ["mcp"]
            }
          }
        }
        """
    }
}
