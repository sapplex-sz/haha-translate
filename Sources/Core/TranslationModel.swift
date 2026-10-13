import Foundation

enum ModelDownloadSource: String, CaseIterable, Identifiable, Sendable {
    case huggingFace
    case modelScope

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .huggingFace: return L("Hugging Face（腾讯仓库）")
        case .modelScope: return L("ModelScope（腾讯混元仓库）")
        }
    }
}

enum ModelDownloadChoice: String, CaseIterable, Identifiable, Sendable {
    case automatic, huggingFace, modelScope
    var id: String { rawValue }
    var explicitSource: ModelDownloadSource? {
        switch self {
        case .automatic: return nil
        case .huggingFace: return .huggingFace
        case .modelScope: return .modelScope
        }
    }
    var displayName: String {
        switch self {
        case .automatic: return L("自动选择（推荐）")
        case .huggingFace: return ModelDownloadSource.huggingFace.displayName
        case .modelScope: return ModelDownloadSource.modelScope.displayName
        }
    }
}

/// Pinned, publisher-provided models. Changing a revision requires re-verifying the LFS digest.
enum TranslationModel: String, CaseIterable, Identifiable, Sendable {
    case light
    case standard

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .light: return L("轻量模型")
        case .standard: return L("专业模型")
        }
    }

    var summary: String {
        switch self {
        case .light: return L("约 462 MB，体积小、启动快，适合日常翻译。")
        case .standard: return L("约 1.13 GB，保留更多模型精度，适合按需进阶。")
        }
    }

    var byteCount: Int64 {
        switch self {
        case .light: return 461_860_800
        case .standard: return 1_133_080_448
        }
    }

    var filename: String {
        switch self {
        case .light: return "Hy-MT2-1.8B-1.25Bit.gguf"
        case .standard: return "Hy-MT2-1.8B-Q4_K_M.gguf"
        }
    }

    var sha256: String {
        switch self {
        case .light: return "cc497fe8f033b52b3b8b00a7669e9661435432f9d4cd43f7ed24400c01507a93"
        case .standard: return "dc5f44fcf1fa496ee7ad725982c0c8c553a4de00259b53af84c4b89fb0c06699"
        }
    }

    var revision: String {
        switch self {
        case .light: return "9df5c824a00a744fb0512a29c640466f4d97dfb0"
        case .standard: return "a0c709d9fac510f2c807aa3af52872340dc37a4a"
        }
    }

    var repository: String {
        switch self {
        case .light: return "tencent/Hy-MT2-1.8B-1.25Bit-GGUF"
        case .standard: return "tencent/Hy-MT2-1.8B-GGUF"
        }
    }

    var downloadURLs: [URL] {
        ModelDownloadSource.allCases.map { downloadURL(for: $0) }
    }

    func downloadURL(for source: ModelDownloadSource) -> URL {
        switch source {
        case .huggingFace:
            return URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(filename)")!
        case .modelScope:
            // Independently verified publisher repository; the identical size and SHA-256
            // above remain mandatory before installation, regardless of download source.
            let repository = self == .light ? "Hy-MT2-1.8B-1.25Bit-GGUF" : "Hy-MT2-1.8B-GGUF"
            let revision = self == .light
                ? "a1ba5a8101d7b257d42c0980e0d6415d0bd9e1cf"
                : "ef1d40b8b315575d30d1eb6579996130b8fc0bb2"
            var url = URLComponents(string: "https://modelscope.cn/api/v1/models/Tencent-Hunyuan/\(repository)/repo")!
            url.queryItems = [URLQueryItem(name: "Revision", value: revision),
                             URLQueryItem(name: "FilePath", value: filename)]
            return url.url!
        }
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }
}
