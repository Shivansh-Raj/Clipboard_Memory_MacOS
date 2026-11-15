import SwiftUI
import ClipboardCore

private extension ContentKind {
    var tint: Color {
        switch self {
        case .text: return .gray
        case .code: return .purple
        case .link: return .blue
        case .email: return .teal
        case .json: return .orange
        case .csv: return .green
        case .markdown: return .indigo
        case .richText: return .pink
        case .image: return .red
        case .file: return .brown
        }
    }
}

private let relativeFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter(); f.unitsStyle = .short; return f
}()
private let absoluteFormatter: DateFormatter = {
    let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; f.doesRelativeDateFormatting = true; return f
}()

private func relativeTime(_ d: Date) -> String {
    if abs(d.timeIntervalSinceNow) < 45 { return "just now" }
    return relativeFormatter.localizedString(for: d, relativeTo: Date())
}

struct HistoryView: View {
    @ObservedObject var vm: HistoryViewModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            filterBar
            Divider().opacity(0.5)
            HStack(spacing: 0) {
                listPane.frame(minWidth: 240, idealWidth: 300, maxWidth: 340)
                Divider().opacity(0.5)
                PreviewPane(vm: vm).frame(maxWidth: .infinity)
            }
            Divider().opacity(0.5)
            footer
        }
        .overlay(alignment: .bottom) {
            if let t = vm.toast {
                Text(t).font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
                    .shadow(radius: 6, y: 2)
                    .padding(.bottom, 34)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.15), value: vm.toast)
        .onChange(of: vm.focusSearchToken) { _ in
            DispatchQueue.main.async { searchFocused = true }
        }
        .onAppear { DispatchQueue.main.async { searchFocused = true } }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 15, weight: .medium))
            TextField("Search clipboard history", text: $vm.search)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($searchFocused)
            if !vm.search.isEmpty {
                Button { vm.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(HistoryFilter.allCases) { f in
                    Button { vm.filter = f } label: {
                        Text(f.title)
                            .font(.system(size: 11.5, weight: vm.filter == f ? .semibold : .regular))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Capsule().fill(vm.filter == f ? Color.accentColor.opacity(0.9) : Color.primary.opacity(0.07)))
                            .foregroundStyle(vm.filter == f ? Color.white : Color.primary.opacity(0.8))
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 10)
        }
    }

    private var listPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if vm.entries.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: vm.search.isEmpty ? "doc.on.clipboard" : "magnifyingglass").font(.system(size: 28)).foregroundStyle(.tertiary)
                        Text(vm.search.isEmpty ? "Nothing here yet" : "No matches").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                        if vm.search.isEmpty && vm.filter == .all {
                            Text("Copy something with ⌘C and it will appear here.").font(.system(size: 11.5)).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                        }
                    }.frame(maxWidth: .infinity).padding(.top, 70).padding(.horizontal, 20)
                } else {
                    LazyVStack(spacing: 2) {
                        Color.clear.frame(height: 0).id("top")
                        ForEach(vm.entries) { entry in
                            EntryRow(entry: entry, selected: entry.id == vm.selectedID)
                                .id(entry.id)
                                .onTapGesture(count: 2) { vm.select(entry.id); vm.copySelected(close: true) }
                                .onTapGesture { vm.select(entry.id) }
                                .onAppear { vm.loadMoreIfNeeded(current: entry) }
                                .contextMenu {
                                    Button("Copy") { vm.select(entry.id); vm.copySelected() }
                                    Button(entry.pinned ? "Unpin" : "Pin") { vm.togglePin(entry) }
                                    Button(entry.favorite ? "Unfavourite" : "Favourite") { vm.toggleFavorite(entry) }
                                    Divider()
                                    Button("Delete", role: .destructive) { vm.deleteSelected(entry) }
                                }
                        }
                    }.padding(.horizontal, 8).padding(.vertical, 6)
                }
            }
            .onChange(of: vm.selectedID) { id in
                if let id { withAnimation(.easeOut(duration: 0.08)) { proxy.scrollTo(id) } }
            }
            .onChange(of: vm.scrollToTop) { _ in proxy.scrollTo("top", anchor: .top) }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Text(vm.total == vm.entries.count || vm.entries.isEmpty ? "\(vm.total) items" : "\(vm.entries.count) of \(vm.total) items")
            Button { vm.clearUnpinned() } label: { Label("Clear", systemImage: "trash.slash") }
                .buttonStyle(.plain).help("Clear history, keeping pinned and favourites")
            Spacer()
            hint("↩", "Copy"); hint("⌘↩", "Copy & close"); hint("⌘P", "Pin"); hint("⌘D", "Favourite"); hint("⌫", "Delete"); hint("⇥", "Filter")
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.vertical, 7)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.system(size: 10.5, weight: .medium, design: .rounded))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
            Text(label)
        }
    }
}

struct EntryRow: View {
    let entry: ClipEntry
    let selected: Bool

    private var title: String {
        switch entry.kind {
        case .image: return "Image · \(entry.imageWidth)×\(entry.imageHeight)"
        default:
            let s = entry.text.prefix(260).trimmingCharacters(in: .whitespacesAndNewlines)
            return s.replacingOccurrences(of: #"\s*\n\s*"#, with: " ⏎ ", options: .regularExpression)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            leading
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(entry.kind == .code || entry.kind == .json ? .system(size: 12.5, design: .monospaced) : .system(size: 13))
                    .lineLimit(2).truncationMode(.tail)
                    .foregroundStyle(selected ? Color.white : Color.primary)
                HStack(spacing: 4) {
                    Text(entry.kind.label)
                    Text("·")
                    if let app = entry.sourceApp { Text(app).lineLimit(1); Text("·") }
                    Text(relativeTime(entry.lastCopiedAt)).lineLimit(1)
                }
                .font(.system(size: 10.5))
                .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
            }
            Spacer(minLength: 0)
            VStack(spacing: 3) {
                if entry.pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(selected ? .white : .orange) }
                if entry.favorite { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(selected ? .white : .yellow) }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor : Color.clear))
        .contentShape(Rectangle())
    }

    @ViewBuilder private var leading: some View {
        if entry.kind == .image, let file = entry.imageFile {
            ThumbnailView(file: file).frame(width: 34, height: 34)
        } else {
            Image(systemName: entry.kind.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(selected ? Color.white : entry.kind.tint)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.white.opacity(0.2) : entry.kind.tint.opacity(0.15)))
        }
    }
}

struct ThumbnailView: View {
    let file: String
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else { Color.primary.opacity(0.08) }
        }
        .frame(width: 34, height: 34).clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear {
            guard image == nil, let url = AppContext.shared?.store.imagesDirectory.appendingPathComponent(file) else { return }
            ThumbnailCache.shared.load(url, size: 68) { image = $0 }
        }
    }
}

struct PreviewPane: View {
    @ObservedObject var vm: HistoryViewModel
    @State private var tagText = ""
    @State private var tagEntryID: Int64?
    @FocusState private var tagFocus: Bool

    var body: some View {
        if let e = vm.selected {
            VStack(alignment: .leading, spacing: 0) {
                header(e)
                Divider().opacity(0.4)
                content(e)
                Divider().opacity(0.4)
                tagsRow(e)
                actionBar(e)
            }
            .onAppear { syncTags(e) }
            .onChange(of: e.id) { _ in syncTags(e) }
            .onChange(of: tagFocus) { vm.editingTags = $0 }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "text.viewfinder").font(.system(size: 30)).foregroundStyle(.tertiary)
                Text("Select an item to preview").font(.system(size: 12)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func syncTags(_ e: ClipEntry) { tagText = e.tags.joined(separator: ", "); tagEntryID = e.id }

    private func header(_ e: ClipEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Label(e.kind.label, systemImage: e.kind.symbol)
                    .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(e.kind.tint)
                if e.kind == .link, let d = ContentClassifier.domain(of: e.text) {
                    Text(d).font(.system(size: 11.5, weight: .medium)).padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.blue.opacity(0.15))).foregroundStyle(.blue)
                }
                Spacer()
                if e.copyCount > 1 { Text("copied \(e.copyCount)×").font(.system(size: 11)).foregroundStyle(.tertiary) }
            }
            HStack(spacing: 4) {
                Text(absoluteFormatter.string(from: e.lastCopiedAt))
                if let app = e.sourceApp { Text("· from \(app)") }
                Text("· " + sizeDescription(e))
            }.font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }.padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func sizeDescription(_ e: ClipEntry) -> String {
        if e.kind == .image { return "\(e.imageWidth)×\(e.imageHeight) · " + ByteCountFormatter.string(fromByteCount: Int64(e.byteSize), countStyle: .file) }
        return "\(e.textLength.formatted()) characters"
    }

    @ViewBuilder private func content(_ e: ClipEntry) -> some View {
        if e.kind == .image, let file = e.imageFile {
            VStack(spacing: 0) {
                LargeImage(file: file).frame(maxWidth: .infinity, maxHeight: .infinity).padding(10)
                if let ocr = e.ocrText, !ocr.isEmpty {
                    Divider().opacity(0.4)
                    ScrollView { Text(ocr).font(.system(size: 11.5)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10) }
                        .frame(maxHeight: 80)
                }
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text(vm.previewText)
                        .font(mono(e.kind) ? .system(size: 12, design: .monospaced) : .system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if e.textLength > 20_000 {
                        Text("Preview shows the first 20,000 of \(e.textLength.formatted()) characters. Copying restores everything.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }.padding(14)
            }.frame(maxHeight: .infinity)
        }
    }

    private func mono(_ k: ContentKind) -> Bool { [.code, .json, .csv, .markdown, .link, .file].contains(k) }

    private func tagsRow(_ e: ClipEntry) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "tag").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("Add tags, separated by commas", text: $tagText)
                .textFieldStyle(.plain).font(.system(size: 12))
                .focused($tagFocus)
                .onSubmit { vm.setTags(e, from: tagText); tagFocus = false; vm.focusSearchToken += 1 }
                .onChange(of: tagFocus) { focused in if !focused, tagEntryID == e.id, tagText != e.tags.joined(separator: ", ") { vm.setTags(e, from: tagText) } }
        }.padding(.horizontal, 14).padding(.vertical, 7)
    }

    private func actionBar(_ e: ClipEntry) -> some View {
        HStack(spacing: 8) {
            Button { vm.copySelected() } label: { Label("Copy", systemImage: "doc.on.doc") }
                .buttonStyle(.borderedProminent).controlSize(.small)
            Button { vm.togglePin() } label: { Image(systemName: e.pinned ? "pin.slash" : "pin") }
                .help(e.pinned ? "Unpin (⌘P)" : "Pin (⌘P)")
            Button { vm.toggleFavorite() } label: { Image(systemName: e.favorite ? "star.fill" : "star") }
                .help("Favourite (⌘D)")
            Button { vm.deleteSelected() } label: { Image(systemName: "trash") }.help("Delete (⌫)")
            Spacer()
            contextual(e)
        }
        .controlSize(.small)
        .padding(.horizontal, 12).padding(.bottom, 10).padding(.top, 2)
    }

    @ViewBuilder private func contextual(_ e: ClipEntry) -> some View {
        switch e.kind {
        case .image:
            Button { vm.extractText() } label: { Label("Extract Text", systemImage: "text.viewfinder") }
            Button { vm.saveImage() } label: { Label("Save…", systemImage: "square.and.arrow.down") }
        case .link:
            Button { vm.openLink() } label: { Label("Open", systemImage: "safari") }
            transformMenu(e)
        case .file:
            EmptyView()
        default:
            transformMenu(e)
        }
    }

    private func transformMenu(_ e: ClipEntry) -> some View {
        Menu {
            if e.kind == .json {
                Button("Format JSON") { vm.transform("Format JSON") { Transforms.formatJSON($0) } }
                Button("Minify JSON") { vm.transform("Minify JSON", Transforms.minifyJSON) }
                Divider()
            }
            Button("Format SQL") { vm.transform("Format SQL", Transforms.formatSQL) }
            Button("UPPERCASE") { vm.transform("Uppercase", Transforms.uppercased) }
            Button("lowercase") { vm.transform("Lowercase", Transforms.lowercased) }
            Button("Clean whitespace") { vm.transform("Clean whitespace", Transforms.cleanWhitespace) }
            Divider()
            Button("Copy without formatting") { vm.copySelected(plain: true) }
        } label: { Label("Transform", systemImage: "wand.and.stars") }
        .menuStyle(.borderlessButton).fixedSize()
    }
}

struct LargeImage: View {
    let file: String
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 6)) }
            else { ProgressView().controlSize(.small) }
        }
        .onAppear(perform: load)
        .onChange(of: file) { _ in image = nil; load() }
    }
    private func load() {
        guard let url = AppContext.shared?.store.imagesDirectory.appendingPathComponent(file) else { return }
        ThumbnailCache.shared.load(url, size: 900) { image = $0 }
    }
}
