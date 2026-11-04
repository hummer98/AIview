import Foundation

/// ViewModel が利用する、完全 URL を key にしたお気に入り snapshot。
/// `lastViewedImage` は単一フォルダを開いた場合だけ有効。
struct FavoriteFolderSnapshot: Sendable {
    let levelsByURL: [URL: Int]
    let lastViewedImage: String?
}

/// お気に入り URL の canonicalization を一箇所に集約する。
/// 相対成分を標準化し、同じ完全パスを常に同じ dictionary key で扱う。
enum FavoriteURLKey {
    nonisolated static func normalize(_ url: URL) -> URL {
        url.standardizedFileURL
    }

    nonisolated static func snapshot(folderURL: URL, favorites: [String: Int]) -> [URL: Int] {
        favorites.reduce(into: [:]) { result, entry in
            let url = folderURL.appendingPathComponent(entry.key)
            result[normalize(url)] = entry.value
        }
    }
}

/// ViewModel から永続化を差し替え可能にする actor 境界。
/// UI はこの repository の内部 state を表示 source にせず、返された snapshot だけを保持する。
protocol FavoritesStoring: Actor {
    func loadSnapshot(for folderURL: URL) -> FavoriteFolderSnapshot
    func loadSnapshot(for folderURLs: [URL]) -> [URL: Int]
    func setFavorite(for url: URL, level: Int) throws
    func removeFavorite(for url: URL) throws
    func setLastViewedImage(_ filename: String, for folderURL: URL)
}
