import SwiftUI
import PhotosUI

struct LibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: PhotoLibraryStore
    @State private var selection: PhotosPickerItem?
    @State private var editing: LibraryPhoto?
    @State private var importing = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if store.photos.isEmpty {
                    ContentUnavailableView("Your photographs", systemImage: "photo.on.rectangle",
                        description: Text("Photos you take or import stay here with their original and editable settings."))
                } else {
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
                            ForEach(store.photos) { photo in
                                Button { editing = photo } label: {
                                    ThumbnailView(url: photo.thumbnailURL)
                                        .aspectRatio(1, contentMode: .fit)
                                        .overlay(alignment: .bottomLeading) {
                                            if photo.hasRaw { Text("RAW").font(.caption2.monospaced()).padding(5).background(.black.opacity(0.6)) }
                                        }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Photo taken \(photo.metadata.date.formatted())")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    PhotosPicker(selection: $selection, matching: .images, photoLibrary: .shared()) {
                        Label("Import", systemImage: "plus")
                    }.disabled(importing)
                }
            }
            .overlay { if importing { ProgressView("Importing…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
            .sheet(item: $editing) { PhotoEditorView(entry: $0, store: store) }
            .onChange(of: selection) { _, item in
                guard let item else { return }
                importing = true
                Task {
                    defer { importing = false; selection = nil }
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else { throw LibraryError.invalidImage }
                        editing = try await store.importPhoto(data: data)
                    } catch { self.error = error.localizedDescription }
                }
            }
            .alert("Could not import photo", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
        .preferredColorScheme(.dark)
        .tint(.white)
    }
}

struct ThumbnailView: View {
    let url: URL?
    @State private var image: UIImage?
    var body: some View {
        GeometryReader { geometry in
            Group {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
                else { Rectangle().fill(.white.opacity(0.08)).overlay(Image(systemName: "photo").foregroundStyle(.secondary)) }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            image = await Task.detached(priority: .utility) { UIImage(contentsOfFile: url.path) }.value
        }
    }
}

struct ShareFiles: Identifiable {
    let id = UUID()
    let urls: [URL]
}

struct ActivitySheet: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
