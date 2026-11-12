import Foundation
import os

/// `BrowserWindowSession` が生成する Task の単一 owner。
/// Task 自身は session を保持せず、scene close 時の cancel で即座に registry から外れる。
private final class BrowserWindowTaskOwner: Sendable {
    private struct State {
        var generation: UUID?
        var task: Task<Void, Never>?
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    func beginReplacingCurrent() -> UUID {
        let generation = UUID()
        let previous = lock.withLock { state -> Task<Void, Never>? in
            let previous = state.task
            state.task = nil
            state.generation = generation
            return previous
        }
        previous?.cancel()
        return generation
    }

    func beginIfIdle() -> UUID? {
        lock.withLock { state in
            guard state.generation == nil else { return nil }
            let generation = UUID()
            state.generation = generation
            return generation
        }
    }

    func install(_ task: Task<Void, Never>, generation: UUID) {
        let accepted = lock.withLock { state in
            guard state.generation == generation else { return false }
            state.task = task
            return true
        }
        if !accepted { task.cancel() }
    }

    func finish(generation: UUID) {
        lock.withLock { state in
            guard state.generation == generation else { return }
            state.task = nil
            state.generation = nil
        }
    }

    func cancel() {
        let task = lock.withLock { state -> Task<Void, Never>? in
            let task = state.task
            state.task = nil
            state.generation = nil
            return task
        }
        task?.cancel()
    }

    var activeTaskCount: Int {
        lock.withLock { $0.generation == nil ? 0 : 1 }
    }

    var currentTask: Task<Void, Never>? {
        lock.withLock { $0.task }
    }

    deinit {
        cancel()
    }
}

/// 非冪等な副作用を入力順に完了させ、scene close でだけ一括終了する直列 queue。
private final class BrowserWindowSerialTaskQueue: Sendable {
    struct Ticket: Sendable {
        let id: UUID
        let predecessor: Task<Void, Never>?
    }

    private struct State {
        var pending: Set<UUID> = []
        var tasks: [UUID: Task<Void, Never>] = [:]
        var tailID: UUID?
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    func begin() -> Ticket {
        let id = UUID()
        return lock.withLock { state in
            let predecessor = state.tailID.flatMap { state.tasks[$0] }
            state.pending.insert(id)
            return Ticket(id: id, predecessor: predecessor)
        }
    }

    func install(_ task: Task<Void, Never>, id: UUID) {
        let accepted = lock.withLock { state in
            guard state.pending.contains(id) else { return false }
            state.tasks[id] = task
            state.tailID = id
            return true
        }
        if !accepted { task.cancel() }
    }

    func finish(id: UUID) {
        lock.withLock { state in
            state.pending.remove(id)
            state.tasks.removeValue(forKey: id)
            if state.tailID == id {
                state.tailID = nil
            }
        }
    }

    func cancelAll() {
        let tasks = lock.withLock { state -> [Task<Void, Never>] in
            let tasks = Array(state.tasks.values)
            state.pending.removeAll()
            state.tasks.removeAll()
            state.tailID = nil
            return tasks
        }
        tasks.forEach { $0.cancel() }
    }

    var activeTaskCount: Int {
        lock.withLock { $0.pending.count }
    }

    var currentTasks: [Task<Void, Never>] {
        lock.withLock { Array($0.tasks.values) }
    }

    deinit {
        cancelAll()
    }
}

private enum BrowserWindowOperation {
    case openFolder(URL)
    case openPath(URL)
    case reloadFolder
    case clearThumbnailCache
    case sibling(SiblingFolderDirection)
    case jumpToIndex(Int)
    case nextImage
    case previousImage
    case setFilter(Int?)
    case setFavorite(Int?)
    case deleteCurrentImage
    case slideshowNavigation(PrefetchDirection)
}

/// 1つの WindowGroup scene に閉じた transient state と Task owner。
@MainActor
@Observable
final class BrowserWindowSession {
    typealias Sleeper = @Sendable (Duration) async throws -> Void
    typealias SideEffectCheckpoint = @Sendable () async -> Void

    let viewModel: ImageBrowserViewModel
    let metricsCollector: MetricsCollector
    let thumbnailActivityModel: ThumbnailActivityModel

    var isFolderPickerPresented = false
    var isFilePathInputPresented = false
    var filePathInput = ""
    private(set) var zoomRequest: BrowserZoomRequest?

    private let appServices: AppServices
    @ObservationIgnored private let folderOperationOwner = BrowserWindowTaskOwner()
    @ObservationIgnored private let navigationOwner = BrowserWindowTaskOwner()
    @ObservationIgnored private let sideEffectTasks = BrowserWindowSerialTaskQueue()
    @ObservationIgnored private let samplingOwner = BrowserWindowTaskOwner()
    @ObservationIgnored private let metricsOwner = BrowserWindowTaskOwner()
    @ObservationIgnored private let samplingSleeper: Sleeper
    @ObservationIgnored private let sideEffectCheckpoint: SideEffectCheckpoint
    @ObservationIgnored private let volumeMonitor: VolumeUnmountMonitor

    init(
        appServices: AppServices,
        viewModel: ImageBrowserViewModel? = nil,
        activitySleeper: ThumbnailActivityModel.Sleeper? = nil,
        samplingSleeper: Sleeper? = nil,
        sideEffectCheckpoint: @escaping SideEffectCheckpoint = {},
        volumeNotificationCenter: NotificationCenter? = nil
    ) {
        self.appServices = appServices
        volumeMonitor = volumeNotificationCenter.map(VolumeUnmountMonitor.init(notificationCenter:))
            ?? VolumeUnmountMonitor()
        let model = viewModel ?? ImageBrowserViewModel(recentFoldersStore: appServices.recentFoldersStore)
        self.viewModel = model

        let metricsCollector = MetricsCollector()
        metricsCollector.bind(
            cacheManager: model.cacheManager,
            thumbnailCacheManager: model.thumbnailCacheManager,
            diskCacheStore: model.diskCacheStore,
            imageLoader: model.imageLoader,
            queueInstrumentation: QueueInstrumentation.thumbnailQueueShared
        )
        self.metricsCollector = metricsCollector
        thumbnailActivityModel = ThumbnailActivityModel(
            metricsCollector: metricsCollector,
            sleeper: activitySleeper
        )
        self.samplingSleeper = samplingSleeper ?? { @Sendable duration in
            try await Task.sleep(for: duration)
        }
        self.sideEffectCheckpoint = sideEffectCheckpoint
    }

    deinit {
        folderOperationOwner.cancel()
        navigationOwner.cancel()
        sideEffectTasks.cancelAll()
        samplingOwner.cancel()
        metricsOwner.cancel()
    }

    var focusedCommands: FocusedBrowserCommands {
        FocusedBrowserCommands(
            hasCurrentFolder: viewModel.currentFolderURL != nil,
            hasImages: viewModel.hasImages,
            showFolderPicker: { [weak self] in self?.presentFolderPicker() },
            showFilePathInput: { [weak self] in self?.presentFilePathInput() },
            openRecentFolder: { [weak self] url in self?.openPath(url) },
            reloadFolder: { [weak self] in self?.perform(.reloadFolder) },
            clearThumbnailCache: { [weak self] in self?.perform(.clearThumbnailCache) },
            moveToSiblingFolder: { [weak self] direction in self?.perform(.sibling(direction)) },
            deleteCurrentImage: { [weak self] in self?.perform(.deleteCurrentImage) },
            zoom: { [weak self] command in self?.requestZoom(command) },
            logMetrics: { [weak self] in self?.logMetrics() }
        )
    }

    func start() {
        startMetricsSampling()
        thumbnailActivityModel.start()
        volumeMonitor.start { [weak self] volumeURL in
            self?.handleVolumeUnmount(volumeURL)
        }
    }

    /// 開いているフォルダのボリュームが外れたら、window の操作 Task も含めて止める。
    func handleVolumeUnmount(_ volumeURL: URL) {
        guard let folderURL = viewModel.currentFolderURL,
              BrowserSessionController.isPath(folderURL, onVolume: volumeURL) else { return }
        folderOperationOwner.cancel()
        navigationOwner.cancel()
        viewModel.handleVolumeUnmount(volumeURL)
    }

    /// scene disappear / close の明示的終了点。
    func stop() {
        volumeMonitor.stop()
        folderOperationOwner.cancel()
        navigationOwner.cancel()
        sideEffectTasks.cancelAll()
        samplingOwner.cancel()
        metricsOwner.cancel()
        thumbnailActivityModel.stop()
        viewModel.sceneDidDisappear()
        isFolderPickerPresented = false
        isFilePathInputPresented = false
        zoomRequest = nil
    }

    func presentFolderPicker() {
        guard !isFolderPickerPresented else { return }
        isFolderPickerPresented = true
    }

    func presentFilePathInput() {
        guard !isFilePathInputPresented else { return }
        filePathInput = ""
        isFilePathInputPresented = true
    }

    func handleFolderPickerResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            if let url = urls.first {
                openFolder(url)
            }
        case .failure(let error):
            viewModel.present(error, operation: .folderSelection)
        }
    }

    func openFolder(_ url: URL) {
        perform(.openFolder(url.standardizedFileURL))
    }

    func openPath(_ url: URL) {
        perform(.openPath(url.standardizedFileURL))
    }

    func jumpToIndex(_ index: Int) {
        perform(.jumpToIndex(index))
    }

    func moveToNext() {
        perform(.nextImage)
    }

    func moveToPrevious() {
        perform(.previousImage)
    }

    func setFilterLevel(_ level: Int?) {
        perform(.setFilter(level))
    }

    func setFavoriteLevel(_ level: Int?) {
        perform(.setFavorite(level))
    }

    func deleteCurrentImage() {
        perform(.deleteCurrentImage)
    }

    func navigateDuringSlideshow(_ direction: PrefetchDirection) {
        perform(.slideshowNavigation(direction))
    }

    func requestZoom(_ command: ZoomCommand) {
        zoomRequest = BrowserZoomRequest(id: UUID(), command: command)
    }

    func consumeZoomRequest(id: UUID) {
        guard zoomRequest?.id == id else { return }
        zoomRequest = nil
    }

    private func perform(_ operation: BrowserWindowOperation) {
        let owner = taskOwner(for: operation)
        let generation = owner?.beginReplacingCurrent()
        let sideEffectTasks = self.sideEffectTasks
        let sideEffectTicket = owner == nil ? sideEffectTasks.begin() : nil
        let sideEffectID = sideEffectTicket?.id
        let model = viewModel
        let services = appServices
        let sideEffectCheckpoint = self.sideEffectCheckpoint
        let task = Task { @MainActor [weak owner, weak sideEffectTasks] in
            defer {
                if let generation {
                    owner?.finish(generation: generation)
                } else if let sideEffectID {
                    sideEffectTasks?.finish(id: sideEffectID)
                }
            }
            if let predecessor = sideEffectTicket?.predecessor {
                await predecessor.value
                guard !Task.isCancelled else { return }
            }
            if sideEffectTicket != nil {
                await sideEffectCheckpoint()
                guard !Task.isCancelled else { return }
            }
            switch operation {
            case .openFolder(let url):
                await model.openFolder(url)
                guard !Task.isCancelled else { return }
                services.refreshRecentFolders()
            case .openPath(let url):
                await model.openPath(url)
                guard !Task.isCancelled else { return }
                services.refreshRecentFolders()
            case .reloadFolder:
                _ = await model.reloadCurrentFolder()
            case .clearThumbnailCache:
                _ = await model.clearThumbnailCacheAndReload()
            case .sibling(let direction):
                await model.moveToSiblingFolder(direction: direction)
                guard !Task.isCancelled else { return }
                services.refreshRecentFolders()
            case .jumpToIndex(let index):
                await model.jumpToIndex(index, recordLastViewed: true)
            case .nextImage:
                await model.moveToNext()
            case .previousImage:
                await model.moveToPrevious()
            case .setFilter(let level):
                if let level {
                    await model.setFilterLevelWithSubdirectories(level)
                } else {
                    await model.clearFilterWithSubdirectories()
                }
            case .setFavorite(let level):
                do {
                    if let level {
                        try await model.setFavoriteLevel(level)
                    } else {
                        try await model.removeFavorite()
                    }
                } catch is CancellationError {
                    return
                } catch {
                    model.present(error, operation: .saveFavorite)
                }
            case .deleteCurrentImage:
                do {
                    try await model.deleteCurrentImage()
                } catch is CancellationError {
                    return
                } catch {
                    model.present(error, operation: .deleteImage)
                }
            case .slideshowNavigation(let direction):
                await model.navigateDuringSlideshow(direction: direction)
            }
        }
        if let owner, let generation {
            owner.install(task, generation: generation)
        } else if let sideEffectID {
            sideEffectTasks.install(task, id: sideEffectID)
        } else {
            task.cancel()
        }
    }

    private func taskOwner(for operation: BrowserWindowOperation) -> BrowserWindowTaskOwner? {
        switch operation {
        case .openFolder, .openPath, .reloadFolder, .clearThumbnailCache, .sibling, .setFilter:
            folderOperationOwner
        case .jumpToIndex, .nextImage, .previousImage, .slideshowNavigation:
            navigationOwner
        case .setFavorite, .deleteCurrentImage:
            nil
        }
    }

    private func startMetricsSampling() {
        guard let generation = samplingOwner.beginIfIdle() else { return }
        let owner = samplingOwner
        let sleeper = samplingSleeper
        let instrumentation = QueueInstrumentation.thumbnailQueueShared
        let task = Task(priority: .background) { [weak owner] in
            defer { owner?.finish(generation: generation) }
            while !Task.isCancelled {
                instrumentation.sample()
                do {
                    try await sleeper(.seconds(1))
                } catch {
                    return
                }
            }
        }
        samplingOwner.install(task, generation: generation)
    }

    private func logMetrics() {
        guard let generation = metricsOwner.beginIfIdle() else { return }
        let owner = metricsOwner
        let collector = metricsCollector
        let task = Task { @MainActor [weak owner] in
            defer { owner?.finish(generation: generation) }
            let snapshot = await collector.snapshot()
            guard !Task.isCancelled else { return }
            Logger.metrics.info("\(snapshot.formattedLogString(), privacy: .private)")
        }
        metricsOwner.install(task, generation: generation)
    }

    #if DEBUG
    struct TaskSnapshot: Equatable {
        let sessionTasks: Int
        let activityTasks: Int

        var isIdle: Bool { sessionTasks == 0 && activityTasks == 0 }
    }

    func _debugTaskSnapshot() -> TaskSnapshot {
        TaskSnapshot(
            sessionTasks: folderOperationOwner.activeTaskCount
                + navigationOwner.activeTaskCount
                + sideEffectTasks.activeTaskCount
                + samplingOwner.activeTaskCount
                + metricsOwner.activeTaskCount,
            activityTasks: thumbnailActivityModel._debugTaskSnapshot().activeTasks
        )
    }

    func _debugWaitForCurrentOperation() async {
        await folderOperationOwner.currentTask?.value
        await navigationOwner.currentTask?.value
        for task in sideEffectTasks.currentTasks {
            await task.value
        }
    }
    #endif
}
