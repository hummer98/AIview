import SwiftUI
import AppKit

/// 画像表示ビュー
/// Requirements: 2.1, 4.3, 11.1
struct ImageDisplayView: View {
    let image: NSImage?
    let isLoading: Bool
    let hasImages: Bool
    var favoriteLevel: Int = 0
    var isFilterEmpty: Bool = false
    /// ズーム状態をリセットする単位（画像の同一性）。切り替わるとフィットに戻す。
    var imageID: String? = nil

    var body: some View {
        ZStack {
            Color.black

            if isFilterEmpty {
                // フィルタリング結果が空
                VStack(spacing: 16) {
                    Image(systemName: "star.slash")
                        .font(.system(size: 64))
                        .foregroundColor(.yellow.opacity(0.5))
                    Text("該当する画像がありません")
                        .foregroundColor(.white.opacity(0.7))
                        .font(.title2)
                    Text("Shift+0でフィルターを解除")
                        .foregroundColor(.white.opacity(0.4))
                        .font(.subheadline)
                }
            } else if isLoading {
                // ローディング中。古い画像は表示せず、ローディングを優先する。
                // これにより「index は進んだのにメイン画像が古いまま」に見える状態を防ぐ
                // （表示確定 currentIndex 自体もロード完了まで進まない）。
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .progressViewStyle(.circular)
                    Text("読み込み中...")
                        .foregroundColor(.white.opacity(0.7))
                }
            } else if let image = image {
                // 画像を表示（ズーム・パン対応）。
                // お気に入りインジケータはズーム変換の影響を受けないよう
                // ZoomableImageView の外側にオーバーレイする。
                ZoomableImageView(image: image, imageID: imageID)
                    .overlay(alignment: .topLeading) {
                        // お気に入りインジケータ（左上・固定）
                        if favoriteLevel > 0 {
                            FavoriteIndicator(level: favoriteLevel, size: .large)
                                .padding(12)
                        }
                    }
            } else if !hasImages {
                // 画像がない
                VStack(spacing: 16) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 64))
                        .foregroundColor(.white.opacity(0.3))
                    Text("画像がありません")
                        .foregroundColor(.white.opacity(0.5))
                        .font(.title2)
                    Text("フォルダを開いて画像を閲覧")
                        .foregroundColor(.white.opacity(0.3))
                        .font(.subheadline)
                }
            } else {
                // エラー状態（画像があるはずだが読み込めない）
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48))
                        .foregroundColor(.orange.opacity(0.7))
                    Text("画像を読み込めませんでした")
                        .foregroundColor(.white.opacity(0.7))
                }
            }
        }
    }
}

/// ズーム・パン対応の画像表示ビュー。
///
/// 倍率モデル: `scale == 1.0` を「ウィンドウにフィット」の基準とする（従来の
/// `.aspectRatio(.fit)` 表示に一致）。拡大するほど `scale` が増える。
/// 「実際のサイズ(100%)」は intrinsic な points 表示に一致する倍率 `1/fitScale`
/// で表現する（`fitScale` = フィット時の intrinsic→表示 縮小率）。
///
/// 操作:
/// - トラックパッドのピンチイン/アウト（`MagnifyGesture`）
/// - 拡大時のドラッグによるパン（`DragGesture`）
/// - メニュー/ショートカット由来の `AppState.zoomCommand`
/// 画像（`imageID`）が切り替わるとフィットへリセットする。
struct ZoomableImageView: View {
    let image: NSImage
    var imageID: String? = nil

    @Environment(AppState.self) private var appState: AppState?

    /// 確定済みの倍率（1.0 = フィット）
    @State private var scale: CGFloat = 1.0
    /// 確定済みのパンオフセット
    @State private var pan: CGSize = .zero
    /// GeometryReader が観測したコンテナサイズ（ジェスチャ/コマンド計算に使用）
    @State private var containerSize: CGSize = .zero

    /// ピンチ中の暫定倍率（ジェスチャ終了で `scale` に確定）
    @GestureState private var gestureMagnify: CGFloat = 1.0
    /// ドラッグ中の暫定移動量（ジェスチャ終了で `pan` に確定）
    @GestureState private var gestureDrag: CGSize = .zero

    private let minScale: CGFloat = 1.0
    private let maxScale: CGFloat = 20.0
    private let stepFactor: CGFloat = 1.25

    var body: some View {
        GeometryReader { geo in
            let effectiveScale = clampedScale(scale * gestureMagnify, container: geo.size)
            let liveOffset = clampedPan(
                CGSize(width: pan.width + gestureDrag.width,
                       height: pan.height + gestureDrag.height),
                container: geo.size,
                scale: effectiveScale
            )
            // フィット(=1.0)より拡大しているときだけパンを許可（内容がはみ出す）
            let canPan = effectiveScale > 1.0 + 0.0001
            // フィットから外れたら倍率バッジを出す（拡大・縮小どちらも）
            let showBadge = abs(effectiveScale - 1.0) > 0.001

            ZStack {
                Color.black

                // ベースは container にフィット（scale 1.0 の基準表示）。
                // その上に scaleEffect / offset を重ねる。
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .scaleEffect(effectiveScale, anchor: .center)
                    .offset(liveOffset)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(magnifyGesture(container: geo.size))
            // フィット時はパンを無効化（ナビの誤操作/意図しない移動を防ぐ）
            .gesture(canPan ? panGesture(container: geo.size) : nil)
            .overlay(alignment: .topTrailing) {
                if showBadge {
                    zoomBadge(percent: percent(scale: effectiveScale, container: geo.size))
                        .padding(12)
                }
            }
            .onAppear { containerSize = geo.size }
            .onChange(of: geo.size) { _, newValue in
                containerSize = newValue
                // リサイズでオフセットが範囲外になり得るため再クランプ
                pan = clampedPan(pan, container: newValue, scale: scale)
            }
        }
        .onChange(of: imageID) { _, _ in
            // 画像切り替え時はフィットへ（アニメーションなし）
            scale = 1.0
            pan = .zero
        }
        .onChange(of: appState?.zoomCommand) { _, command in
            handleZoomCommand(command)
        }
    }

    // MARK: - Zoom Command

    private func handleZoomCommand(_ command: ZoomCommand?) {
        guard let command else { return }
        let container = containerSize

        withAnimation(.easeInOut(duration: 0.15)) {
            switch command {
            case .zoomIn:
                applyScale(scale * stepFactor, container: container)
            case .zoomOut:
                applyScale(scale / stepFactor, container: container)
            case .fit:
                scale = 1.0
                pan = .zero
            case .actualSize:
                let fit = fitScale(container: container)
                applyScale(fit > 0 ? 1.0 / fit : 1.0, container: container)
            }
        }
        appState?.clearZoomCommand()
    }

    /// 倍率を設定し、パンを新しい倍率でクランプし直す
    private func applyScale(_ newScale: CGFloat, container: CGSize) {
        scale = clampedScale(newScale, container: container)
        pan = clampedPan(pan, container: container, scale: scale)
    }

    // MARK: - Gestures

    private func magnifyGesture(container: CGSize) -> some Gesture {
        MagnifyGesture()
            .updating($gestureMagnify) { value, state, _ in
                state = value.magnification
            }
            .onEnded { value in
                applyScale(scale * value.magnification, container: container)
            }
    }

    private func panGesture(container: CGSize) -> some Gesture {
        DragGesture()
            .updating($gestureDrag) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                pan = clampedPan(
                    CGSize(width: pan.width + value.translation.width,
                           height: pan.height + value.translation.height),
                    container: container,
                    scale: scale
                )
            }
    }

    // MARK: - Geometry Helpers

    /// intrinsic な画像サイズ（points）
    private var imagePointSize: CGSize { image.size }

    /// フィット時の intrinsic→表示 縮小率
    private func fitScale(container: CGSize) -> CGFloat {
        let img = imagePointSize
        guard img.width > 0, img.height > 0, container.width > 0, container.height > 0 else {
            return 1.0
        }
        return min(container.width / img.width, container.height / img.height)
    }

    /// フィット時に画面上で占めるサイズ（scale 1.0 のときの表示サイズ）
    private func fittedDisplaySize(container: CGSize) -> CGSize {
        let f = fitScale(container: container)
        return CGSize(width: imagePointSize.width * f, height: imagePointSize.height * f)
    }

    /// 倍率のクランプ。
    /// - 上限: maxScale（ただし「実際のサイズ100%」には常に到達できるよう引き上げる）
    /// - 下限: フィット(1.0) と 実際のサイズ の小さい方。
    ///   これにより intrinsic がウィンドウより小さい画像でも 100%（フィットより小さい）
    ///   まで縮小できる。大きい画像ではフィットが下限になる（それ以上は縮まない）。
    private func clampedScale(_ value: CGFloat, container: CGSize) -> CGFloat {
        let fit = fitScale(container: container)
        let actual = fit > 0 ? 1.0 / fit : 1.0
        let upper = max(maxScale, actual)
        let lower = min(minScale, actual)
        return min(max(value, lower), upper)
    }

    /// パンオフセットを、拡大した画像がコンテナからはみ出す範囲内にクランプ
    private func clampedPan(_ proposed: CGSize, container: CGSize, scale: CGFloat) -> CGSize {
        let disp = fittedDisplaySize(container: container)
        let scaledW = disp.width * scale
        let scaledH = disp.height * scale
        let maxX = max(0, (scaledW - container.width) / 2)
        let maxY = max(0, (scaledH - container.height) / 2)
        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY)
        )
    }

    /// 表示倍率（intrinsic 比）を % で返す。フィット時 = fitScale*100、実寸時 = 100。
    private func percent(scale: CGFloat, container: CGSize) -> Int {
        Int((fitScale(container: container) * scale * 100).rounded())
    }

    // MARK: - Zoom Badge

    private func zoomBadge(percent: Int) -> some View {
        Text("\(percent)%")
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.55), in: Capsule())
    }
}

#Preview("With Image") {
    ImageDisplayView(
        image: NSImage(systemSymbolName: "photo", accessibilityDescription: nil),
        isLoading: false,
        hasImages: true
    )
    .frame(width: 600, height: 400)
}

#Preview("Loading") {
    ImageDisplayView(
        image: nil,
        isLoading: true,
        hasImages: true
    )
    .frame(width: 600, height: 400)
}

#Preview("No Images") {
    ImageDisplayView(
        image: nil,
        isLoading: false,
        hasImages: false
    )
    .frame(width: 600, height: 400)
}
