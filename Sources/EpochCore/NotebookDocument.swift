import Foundation

public struct NotebookDocument: Hashable, Sendable, Decodable {
    public struct Cell: Hashable, Sendable {
        public enum CellType: String, Hashable, Sendable {
            case markdown
            case code
            case raw
            case unknown
        }

        public var cellType: CellType
        public var source: String
        public var executionCount: Int?
        public var outputs: [Output]
    }

    public enum Output: Hashable, Sendable {
        public struct RichData: Hashable, Sendable {
            public var textPlain: String?
            public var html: String?
            public var imagePNGBase64: String?
            public var imageJPEGBase64: String?

            public init(textPlain: String? = nil, html: String? = nil, imagePNGBase64: String? = nil, imageJPEGBase64: String? = nil) {
                self.textPlain = textPlain
                self.html = html
                self.imagePNGBase64 = imagePNGBase64
                self.imageJPEGBase64 = imageJPEGBase64
            }
        }

        case stream(name: String?, text: String)
        case error(ename: String?, evalue: String?, traceback: String)
        case rich(RichData)
    }

    public var language: String
    public var cells: [Cell]

    public static func decode(from json: String) throws -> NotebookDocument {
        try JSONDecoder().decode(NotebookDocument.self, from: Data(json.utf8))
    }

    public init(from decoder: Decoder) throws {
        let raw = try RawNotebook(from: decoder)

        let language = raw.metadata?.languageInfo?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.language = (language?.isEmpty == false ? language! : "python").lowercased()

        self.cells = raw.cells.map { rawCell in
            let type = Cell.CellType(rawValue: rawCell.cellType) ?? .unknown
            let outputs = (rawCell.outputs ?? []).compactMap { rawOutput -> Output? in
                switch rawOutput.outputType {
                case "stream":
                    let text = rawOutput.text?.value ?? ""
                    return .stream(name: rawOutput.name, text: text)
                case "error":
                    let traceback = (rawOutput.traceback ?? []).joined(separator: "\n")
                    return .error(ename: rawOutput.ename, evalue: rawOutput.evalue, traceback: traceback)
                case "execute_result", "display_data":
                    let data = rawOutput.data ?? [:]
                    let rich = Output.RichData(
                        textPlain: data["text/plain"]?.value,
                        html: data["text/html"]?.value,
                        imagePNGBase64: data["image/png"]?.value,
                        imageJPEGBase64: data["image/jpeg"]?.value
                    )
                    return .rich(rich)
                default:
                    return nil
                }
            }

            return Cell(
                cellType: type,
                source: rawCell.source.value,
                executionCount: rawCell.executionCount,
                outputs: outputs
            )
        }
    }
}

private struct RawNotebook: Decodable {
    var cells: [RawCell]
    var metadata: RawMetadata?
}

private struct RawMetadata: Decodable {
    var languageInfo: RawLanguageInfo?

    private enum CodingKeys: String, CodingKey {
        case languageInfo = "language_info"
    }
}

private struct RawLanguageInfo: Decodable {
    var name: String?
}

private struct RawCell: Decodable {
    var cellType: String
    var source: NotebookText
    var executionCount: Int?
    var outputs: [RawOutput]?

    private enum CodingKeys: String, CodingKey {
        case cellType = "cell_type"
        case source
        case executionCount = "execution_count"
        case outputs
    }
}

private struct RawOutput: Decodable {
    var outputType: String
    var name: String?
    var text: NotebookText?
    var ename: String?
    var evalue: String?
    var traceback: [String]?
    var data: [String: NotebookText]?

    private enum CodingKeys: String, CodingKey {
        case outputType = "output_type"
        case name
        case text
        case ename
        case evalue
        case traceback
        case data
    }
}

private struct NotebookText: Decodable, Hashable, Sendable {
    var value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
            return
        }
        if let parts = try? container.decode([String].self) {
            value = parts.joined()
            return
        }
        value = ""
    }
}

