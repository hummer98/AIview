import SwiftUI
import AppKit

/// 画像情報パネル
/// Requirements: 5.1-5.7
struct InfoPanel: View {
    let metadata: ImageMetadata
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ヘッダー
            HStack {
                Text("画像情報")
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color.black.opacity(0.9))

            Divider()
                .background(Color.white.opacity(0.2))

            // コンテンツ
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 基本情報
                    infoSection(title: "ファイル情報") {
                        infoRow(label: "ファイル名", value: metadata.fileName)
                        infoRow(label: "サイズ", value: formatFileSize(metadata.fileSize))
                        infoRow(label: "解像度", value: "\(Int(metadata.imageSize.width)) × \(Int(metadata.imageSize.height))")
                        if let date = metadata.creationDate {
                            infoRow(label: "作成日時", value: formatDate(date))
                        }
                    }

                    // プロンプト情報
                    if metadata.prompt != nil || metadata.negativePrompt != nil {
                        infoSection(title: "生成情報") {
                            if let prompt = metadata.prompt {
                                promptSection(title: "プロンプト", content: prompt)
                            }
                            if let negativePrompt = metadata.negativePrompt {
                                promptSection(title: "ネガティブプロンプト", content: negativePrompt)
                            }
                        }
                    }

                    // 追加情報
                    if !metadata.additionalInfo.isEmpty {
                        infoSection(title: "その他") {
                            ForEach(Array(metadata.additionalInfo.keys.sorted()), id: \.self) { key in
                                if let value = metadata.additionalInfo[key] {
                                    infoRow(label: key, value: value)
                                }
                            }
                        }
                    }
                }
                .padding()
            }
        }
        .background(Color(white: 0.15))
    }

    // MARK: - Components

    private func infoSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.6))
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 6) {
                content()
            }
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundColor(.white.opacity(0.5))
                .frame(width: 80, alignment: .leading)

            Text(value)
                .font(.caption)
                .foregroundColor(.white)
                .textSelection(.enabled)

            Spacer()
        }
    }

    private func promptSection(title: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))

                Spacer()

                Button {
                    copyToClipboard(content)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help("クリップボードにコピー")
            }

            Text(content)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.9))
                .textSelection(.enabled)
                .padding(8)
                .background(Color.black.opacity(0.3))
                .cornerRadius(4)
        }
    }

    // MARK: - Helpers

    private func formatFileSize(_ size: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "ja_JP")
        return formatter.string(from: date)
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

#Preview {
    InfoPanel(
        metadata: ImageMetadata(
            fileName: "generated_image_001.png",
            fileSize: 1_234_567,
            imageSize: CGSize(width: 1024, height: 1024),
            creationDate: Date(),
            prompt: "beautiful landscape, mountains, sunset, masterpiece, best quality",
            negativePrompt: "ugly, blurry, bad quality, worst quality",
            additionalInfo: ["撮影日時": "2024-01-01 12:00:00"]
        ),
        onClose: {}
    )
    .frame(width: 320, height: 500)
}
