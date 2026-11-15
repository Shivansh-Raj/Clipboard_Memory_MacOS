import AppKit
import ClipboardCore

final class HistoryViewModel: ObservableObject {
    let store: HistoryStore
    let writer: PasteboardWriter

    @Published var search = "" { didSet { if search != oldValue { reload() } } }
    @Published var filter: HistoryFilter = .all { didSet { if filter != oldValue { reload() } } }
    @Published private(set) var entries: [ClipEntry] = []
    @Published private(set) var total = 0
    @Published var selectedID: Int64?
    @Published private(set) var previewText: String = ""
    @Published var toast: String?
    @Published var focusSearchToken = 0
    @Published var editingTags = false
    @Published var scrollToTop = 0

    var onClose: (() -> Void)?
    var beginModal: (() -> Void)?
    var endModal: (() -> Void)?

    private let queryQueue = DispatchQueue(label: "history.query", qos: .userInitiated)
    private var generation = 0
    private let pageSize = 100
    private var toastGeneration = 0
    private var observer: NSObjectProtocol?

    init(store: HistoryStore, writer: PasteboardWriter) {
        self.store = store
        self.writer = writer
        observer = NotificationCenter.default.addObserver(forName: .historyChanged, object: nil, queue: .main) { [weak self] _ in
            self?.reload(resetScroll: false)
        }
    }

    var selected: ClipEntry? { entries.first { $0.id == selectedID } }

    // MARK: Loading

    func prepareForShow() {
        search = ""
        filter = .all
        editingTags = false
        reload(selectFirst: true)
        scrollToTop += 1
        focusSearchToken += 1
    }

    func reload(selectFirst: Bool = false, resetScroll: Bool = true) {
        generation += 1
        let gen = generation
        let q = search, f = filter, limit = max(pageSize, entries.count > pageSize && !resetScroll ? entries.count : pageSize)
        queryQueue.async { [store] in
            let rows = store.fetch(search: q, filter: f, limit: limit)
            let total = store.count(search: q, filter: f)
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                self.entries = rows
                self.total = total
                if selectFirst || !rows.contains(where: { $0.id == self.selectedID }) { self.selectedID = rows.first?.id }
                self.refreshPreview()
            }
        }
    }

    func loadMoreIfNeeded(current: ClipEntry) {
        guard current.id == entries.last?.id, entries.count < total else { return }
        let offset = entries.count, gen = generation, q = search, f = filter
        queryQueue.async { [store] in
            let more = store.fetch(search: q, filter: f, limit: self.pageSize, offset: offset)
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                let known = Set(self.entries.map(\.id))
                self.entries.append(contentsOf: more.filter { !known.contains($0.id) })
            }
        }
    }

    func refreshPreview() {
        guard let e = selected else { previewText = ""; return }
        if e.kind == .image { previewText = e.ocrText ?? ""; return }
        previewText = e.text
        guard e.isTruncated else { return }
        let id = e.id
        queryQueue.async { [store] in
            let full = store.payload(id: id)?.text ?? ""
            DispatchQueue.main.async { if self.selectedID == id { self.previewText = String(full.prefix(20_000)) } }
        }
    }

    // MARK: Navigation

    func move(_ delta: Int) {
        guard !entries.isEmpty else { return }
        let idx = entries.firstIndex { $0.id == selectedID } ?? (delta > 0 ? -1 : entries.count)
        let next = min(max(idx + delta, 0), entries.count - 1)
        selectedID = entries[next].id
        refreshPreview()
        if next == entries.count - 1 { loadMoreIfNeeded(current: entries[next]) }
    }

    func select(_ id: Int64) { selectedID = id; refreshPreview() }

    func cycleFilter(_ delta: Int) {
        let all = HistoryFilter.allCases
        let i = all.firstIndex(of: filter) ?? 0
        filter = all[(i + delta + all.count) % all.count]
    }

    // MARK: Actions

    func showToast(_ message: String) {
        toastGeneration += 1
        let g = toastGeneration
        toast = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { if g == self.toastGeneration { self.toast = nil } }
    }

    func copySelected(plain: Bool = false, close: Bool = false) {
        guard let e = selected else { return }
        if writer.restore(id: e.id, plain: plain) {
            showToast(plain ? "Copied as plain text" : "Copied to clipboard")
            reload(resetScroll: false)
            if close { onClose?() }
        } else { showToast("Couldn’t restore this item") }
    }

    func togglePin(_ e: ClipEntry? = nil) {
        guard let e = e ?? selected else { return }
        store.setPinned(e.id, !e.pinned)
        showToast(e.pinned ? "Unpinned" : "Pinned")
        reload(resetScroll: false)
    }

    func toggleFavorite(_ e: ClipEntry? = nil) {
        guard let e = e ?? selected else { return }
        store.setFavorite(e.id, !e.favorite)
        showToast(e.favorite ? "Removed from favourites" : "Added to favourites")
        reload(resetScroll: false)
    }

    func deleteSelected(_ e: ClipEntry? = nil) {
        guard let e = e ?? selected else { return }
        let idx = entries.firstIndex { $0.id == e.id }
        store.delete(ids: [e.id])
        if let idx, e.id == selectedID {
            let rest = entries.filter { $0.id != e.id }
            selectedID = rest.isEmpty ? nil : rest[min(idx, rest.count - 1)].id
        }
        showToast("Deleted")
        reload(resetScroll: false)
    }

    func setTags(_ e: ClipEntry, from text: String) {
        store.setTags(e.id, text.split(separator: ",").map(String.init))
        reload(resetScroll: false)
    }

    /// Runs a transformation, stores the result as its own entry and puts it on the clipboard.
    func transform(_ name: String, _ fn: (String) -> String?) {
        guard let e = selected, let full = store.payload(id: e.id)?.text else { return }
        guard let result = fn(full) else { showToast("\(name) isn’t possible for this content"); return }
        guard result != full else { showToast("Nothing to change"); return }
        writer.write(text: result)
        let kind = ContentClassifier.classify(result)
        if let saved = try? store.save(NewClip(kind: kind, text: result, sourceApp: "Clipboard Memory")) {
            selectedID = saved.id
        }
        search = ""; filter = .all
        reload(selectFirst: false, resetScroll: true)
        scrollToTop += 1
        showToast("\(name) – copied as new entry")
    }

    func openLink() {
        guard let e = selected else { return }
        var s = e.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("www.") { s = "https://" + s }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(), ["http", "https", "mailto", "ftp"].contains(scheme) else {
            showToast("Not a web link"); return
        }
        NSWorkspace.shared.open(url)
        onClose?()
    }

    func saveImage() {
        guard let e = selected, let file = e.imageFile else { return }
        let src = store.imagesDirectory.appendingPathComponent(file)
        beginModal?()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Clipboard Image.png"
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        endModal?()
        guard response == .OK, let dest = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.copyItem(at: src, to: dest)
            showToast("Image saved")
        } catch { showToast("Couldn’t save the image") }
    }

    func extractText() {
        guard let e = selected, let file = e.imageFile else { return }
        showToast("Reading text…")
        OCR.recognize(imageAt: store.imagesDirectory.appendingPathComponent(file)) { [weak self] text in
            guard let self else { return }
            if text.isEmpty { self.showToast("No text found in image"); return }
            self.store.setOCR(e.id, text)
            self.writer.write(text: text)
            if let saved = try? self.store.save(NewClip(kind: ContentClassifier.classify(text), text: text, sourceApp: "Clipboard Memory")) {
                _ = saved
            }
            self.showToast("Text extracted – copied to clipboard")
            self.reload(resetScroll: false)
        }
    }
}
