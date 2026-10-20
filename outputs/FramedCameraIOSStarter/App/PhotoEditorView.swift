import SwiftUI

struct PhotoEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: PhotoLibraryStore
    let entry: LibraryPhoto
    @State private var recipe: EditRecipe
    @State private var preview: UIImage?
    @State private var category = "Looks"
    @State private var hueChannel = 0
    @State private var showOriginal = false
    @State private var busy = false
    @State private var status: String?
    @State private var files: ShareFiles?
    @State private var confirmDelete = false
    @State private var deleted = false
    private let categories = ["Looks", "Light", "Color", "HSL", "Grade", "Curves", "Effects", "Finish"]

    init(entry: LibraryPhoto, store: PhotoLibraryStore) {
        self.entry = entry; self.store = store
        _recipe = State(initialValue: entry.recipe)
    }

    private var renderRecipe: EditRecipe {
        if showOriginal { var original = EditRecipe(); original.aspect = recipe.aspect; return original }
        return recipe
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    Color.black
                    if let preview { Image(uiImage: preview).resizable().scaledToFit().padding(8) }
                    else { ProgressView("Developing photo…") }
                }
                .frame(maxHeight: .infinity)
                .overlay(alignment: .topTrailing) {
                    Button(showOriginal ? "Edited" : "Original") { showOriginal.toggle() }
                        .font(.caption).padding(10).background(.black.opacity(0.7), in: Capsule()).padding(12)
                }
                if let status { Text(status).font(.footnote).foregroundStyle(.secondary).padding(.horizontal).padding(.vertical, 6) }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 20) {
                        ForEach(categories, id: \.self) { name in
                            Button(name) { category = name }
                                .foregroundStyle(category == name ? .yellow : .secondary)
                                .font(.subheadline.weight(category == name ? .semibold : .regular))
                                .frame(minHeight: 44)
                        }
                    }.padding(.horizontal)
                }
                Divider()
                ScrollView { editorControls.padding() }
                    .frame(height: 230)
                    .background(Color(uiColor: .secondarySystemBackground))
            }
            .navigationTitle(entry.hasRaw ? "Develop RAW" : "Develop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { persistAndDismiss() }.disabled(busy) }
                ToolbarItem(placement: .topBarTrailing) {
                    if busy { ProgressView() }
                    else {
                        Menu {
                            Button("Save edit to Photos", systemImage: "square.and.arrow.down") { export(save: true) }
                            Button("Share edit", systemImage: "square.and.arrow.up") { export(save: false) }
                            Button("Save original + RAW", systemImage: "doc") { saveOriginal() }
                            Button("Share original files", systemImage: "doc.on.doc") {
                                files = ShareFiles(urls: entry.hasRaw ? [entry.originalURL, entry.rawURL] : [entry.originalURL])
                            }
                            Button("Reset edits", systemImage: "arrow.counterclockwise") {
                                let aspect = recipe.aspect; recipe = EditRecipe(); recipe.aspect = aspect
                            }
                            Button("Delete from Still", systemImage: "trash", role: .destructive) { confirmDelete = true }
                        } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
                    }
                }
            }
            .task(id: renderRecipe) {
                do {
                    try await Task.sleep(for: .milliseconds(150))
                    let image = try await PhotoRenderer.shared.render(entry, recipe: renderRecipe)
                    try Task.checkCancellation()
                    preview = image
                } catch is CancellationError {} catch { status = error.localizedDescription }
            }
            .onDisappear {
                guard !deleted else { return }
                var updated = entry; updated.recipe = recipe
                Task { do { try await store.update(updated) } catch { store.error = error.localizedDescription } }
            }
            .sheet(item: $files) { ActivitySheet(urls: $0.urls) }
            .confirmationDialog("Delete this photo and its edits from Still?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    Task { do { try await store.delete(entry); deleted = true; dismiss() } catch { status = error.localizedDescription } }
                }
            }
        }
        .preferredColorScheme(.dark).tint(.white)
        .interactiveDismissDisabled(busy)
    }

    @ViewBuilder private var editorControls: some View {
        switch category {
        case "Looks":
            VStack(alignment: .leading, spacing: 15) {
                Text("Start with a look, then adjust it.").font(.footnote).foregroundStyle(.secondary)
                ForEach(PhotoRenderer.looks, id: \.self) { name in
                    Button { recipe.look = name } label: {
                        HStack { Text(name); Spacer(); if recipe.look == name { Image(systemName: "checkmark") } }.frame(minHeight: 36)
                    }
                }
            }
        case "Light":
            VStack { adjustment("Exposure", "exposure", -2...2); adjustment("Contrast", "contrast"); adjustment("Highlights", "highlights"); adjustment("Shadows", "shadows"); adjustment("Whites", "whites"); adjustment("Blacks", "blacks"); adjustment("Fade", "fade", 0...1) }
        case "Color":
            VStack { adjustment("Temperature", "temperature"); adjustment("Tint", "tint"); adjustment("Saturation", "saturation"); Text("Sensor color calibration").font(.footnote).foregroundStyle(.secondary); adjustment("Red", "red"); adjustment("Green", "green"); adjustment("Blue", "blue") }
        case "HSL":
            VStack {
                Picker("Color channel", selection: $hueChannel) {
                    ForEach(0..<6) { index in Text(["Red", "Yellow", "Green", "Cyan", "Blue", "Magenta"][index]).tag(index) }
                }.pickerStyle(.menu)
                valueSlider("Hue", value: $recipe.hue[hueChannel], range: -1...1)
                valueSlider("Saturation", value: $recipe.saturation[hueChannel], range: -1...1)
                valueSlider("Luminance", value: $recipe.luminance[hueChannel], range: -1...1)
            }
        case "Grade":
            VStack { adjustment("Shadow hue", "shadowHue", 0...1); adjustment("Shadow strength", "shadowColor", 0...1); adjustment("Highlight hue", "highlightHue", 0...1); adjustment("Highlight strength", "highlightColor", 0...1) }
        case "Curves":
            VStack {
                Text("Tone curve").font(.headline)
                ForEach(0..<5) { index in
                    valueSlider(["Black", "Shadows", "Midtones", "Highlights", "White"][index], value: $recipe.curve[index], range: 0...1)
                }
            }
        case "Effects":
            VStack { adjustment("Grain", "grain", 0...1); adjustment("Halation / bloom", "halation", 0...1); adjustment("Glow", "glow", 0...1); adjustment("Light leak", "leak", 0...1); adjustment("Scratches", "scratches", 0...1); adjustment("Dust", "dust", 0...1); adjustment("Motion", "motion", 0...1); adjustment("Vignette", "vignette", 0...1) }
        default:
            VStack {
                Picker("Crop", selection: $recipe.aspect) { ForEach(CaptureAspect.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                Picker("Border", selection: $recipe.frame) { ForEach(PhotoRenderer.frames, id: \.self) { Text($0).tag($0) } }.pickerStyle(.menu)
                Toggle("Capture date stamp", isOn: $recipe.dateStamp)
                Text("Edits are stored separately. The original and RAW file are retained.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func adjustment(_ title: String, _ key: String, _ range: ClosedRange<Double> = -1...1) -> some View {
        valueSlider(title, value: Binding(get: { recipe[key] }, set: { recipe[key] = $0 }), range: range)
    }
    private func valueSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(spacing: 3) {
            HStack { Text(title); Spacer(); Text(value.wrappedValue, format: .number.precision(.fractionLength(2))).monospacedDigit().foregroundStyle(.secondary) }.font(.caption)
            Slider(value: value, in: range).accessibilityLabel(title).tint(.white)
        }.padding(.bottom, 9)
    }

    private func persistAndDismiss() {
        busy = true
        Task {
            do { var updated = entry; updated.recipe = recipe; try await store.update(updated); dismiss() }
            catch { status = error.localizedDescription }
            busy = false
        }
    }

    private func export(save: Bool) {
        busy = true
        let exportRecipe = recipe
        Task {
            defer { busy = false }
            do {
                let image = try await PhotoRenderer.shared.render(entry, recipe: exportRecipe, maximumSide: nil)
                guard let data = await Task.detached(priority: .userInitiated, operation: {
                    image.jpegData(compressionQuality: 0.95)
                }).value else { throw LibraryError.invalidImage }
                if save {
                    try await PhotosWriter.save(data: data, date: entry.metadata.date)
                    status = "Saved to Photos."
                } else {
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("Still-\(entry.id.uuidString).jpg")
                    try await Task.detached(priority: .userInitiated) { try data.write(to: url, options: .atomic) }.value
                    files = ShareFiles(urls: [url])
                }
                var updated = entry; updated.recipe = recipe; try await store.update(updated)
            } catch { status = error.localizedDescription }
        }
    }

    private func saveOriginal() {
        busy = true
        Task {
            defer { busy = false }
            do {
                let result = try await Task.detached(priority: .utility) {
                    (try Data(contentsOf: entry.originalURL), entry.hasRaw ? try Data(contentsOf: entry.rawURL) : nil)
                }.value
                try await PhotosWriter.save(data: result.0, raw: result.1, date: entry.metadata.date)
                status = "Original saved to Photos."
            } catch { status = error.localizedDescription }
        }
    }
}
