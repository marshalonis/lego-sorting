import SwiftUI
import PhotosUI

struct IdentifyView: View {
    @EnvironmentObject var api: APIService

    @State private var selectedItem: PhotosPickerItem?
    @State private var selectedImage: UIImage?
    @State private var isIdentifying = false
    @State private var result: IdentifyResponse?
    @State private var errorMessage: String?

    @State private var catalogQuery = ""
    @State private var catalogResults: [CatalogPart] = []
    @State private var catalogSearchTask: Task<Void, Never>?

    @State private var manualPartNum = ""
    @State private var lookupResult: LookupResponse?
    @State private var isLookingUp = false

    @State private var showDrawerPicker = false
    @State private var showEditPart = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    imagePickerSection
                    catalogSearchSection
                    if isIdentifying {
                        loadingCard
                    } else if let result {
                        resultSection(result)
                    }
                }
                .padding()
            }
            .navigationTitle("Identify Part")
            .sheet(isPresented: $showDrawerPicker) {
                if let result {
                    DrawerPickerSheet(
                        ai: result.ai,
                        manualPartNum: manualPartNum,
                        onSaved: { updatedResult in
                            self.result = updatedResult
                            showDrawerPicker = false
                        }
                    )
                }
            }
            .sheet(isPresented: $showEditPart) {
                if let part = result?.existing {
                    EditPartSheet(part: part, onSaved: { _ in showEditPart = false })
                }
            }
        }
    }

    // MARK: - Image picker

    private var imagePickerSection: some View {
        VStack(spacing: 12) {
            if let image = selectedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                Button("Try Another") {
                    selectedImage = nil
                    result = nil
                    errorMessage = nil
                    manualPartNum = ""
                    lookupResult = nil
                }
                .buttonStyle(.bordered)
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.secondarySystemBackground))
                    .frame(height: 200)
                    .overlay {
                        VStack(spacing: 12) {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 44))
                                .foregroundColor(.secondary)
                            Text("Tap to take photo or choose image")
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                            PhotosPicker(
                                selection: $selectedItem,
                                matching: .images,
                                photoLibrary: .shared()
                            ) {
                                Text("Choose Image")
                                    .buttonStyle(.borderedProminent)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.caption)
            }
        }
        .onChange(of: selectedItem) { _, item in
            Task { await loadImage(from: item) }
        }
    }

    private func loadImage(from item: PhotosPickerItem?) async {
        guard let item else { return }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }
        selectedImage = image
        result = nil
        errorMessage = nil
        manualPartNum = ""
        lookupResult = nil
        await identifyImage(image)
    }

    private func identifyImage(_ image: UIImage) async {
        isIdentifying = true
        errorMessage = nil
        do {
            let imageData = api.compressImage(image)
            let upload = try await api.getUploadURL()
            try await api.uploadImageToS3(url: upload.uploadURL, data: imageData)
            let response = try await api.identify(s3Key: upload.s3Key)
            result = response
            manualPartNum = response.ai.partNum ?? ""
        } catch {
            errorMessage = error.localizedDescription
        }
        isIdentifying = false
    }

    // MARK: - Catalog search

    private var catalogSearchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Search by name")
                .font(.caption)
                .foregroundColor(.secondary)

            TextField("e.g. 1x2 plate, technic axle…", text: $catalogQuery)
                .textFieldStyle(.roundedBorder)
                .onChange(of: catalogQuery) { _, q in
                    catalogSearchTask?.cancel()
                    catalogResults = []
                    guard q.count >= 2 else { return }
                    catalogSearchTask = Task {
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        guard !Task.isCancelled else { return }
                        if let results = try? await api.catalogSearch(query: q) {
                            catalogResults = results
                        }
                    }
                }

            if !catalogResults.isEmpty {
                VStack(spacing: 6) {
                    ForEach(catalogResults.prefix(8)) { part in
                        Button(action: { selectCatalogPart(part) }) {
                            HStack(spacing: 10) {
                                AsyncImage(url: part.imageURL) { img in
                                    img.resizable().scaledToFit()
                                } placeholder: {
                                    Color(.systemGray5)
                                }
                                .frame(width: 40, height: 40)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 6))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(part.name).font(.subheadline).fontWeight(.semibold)
                                    Text("#\(part.partNum)").font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                if let loc = part.locationDisplay {
                                    Text(loc).font(.caption2).foregroundColor(.green)
                                } else {
                                    Text("Not cataloged").font(.caption2).foregroundColor(.orange)
                                }
                            }
                            .padding(8)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func selectCatalogPart(_ part: CatalogPart) {
        catalogQuery = ""
        catalogResults = []
        manualPartNum = part.partNum
        Task { await relookup(partNum: part.partNum) }
    }

    // MARK: - Loading

    private var loadingCard: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("Identifying part…").foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Result

    @ViewBuilder
    private func resultSection(_ response: IdentifyResponse) -> some View {
        let ai = response.ai
        let conf = ai.confidence

        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(ai.name).font(.title3.bold())
                    Text([ai.partNum.map { "#\($0)" }, ai.category, ai.color]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                confidenceBadge(conf)
            }

            if let desc = ai.description, !desc.isEmpty {
                Text(desc).font(.subheadline).foregroundColor(.secondary)
            }

            // Location
            if let loc = response.location {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text(loc.display).font(.subheadline).fontWeight(.semibold)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text("Not yet cataloged").font(.subheadline).fontWeight(.semibold)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Actions
            if response.location != nil {
                Button("Edit / Move Part") { showEditPart = true }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
            } else {
                Button("Assign to Drawer") { showDrawerPicker = true }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
            }

            // Part image from Brick Architect
            if let partNum = ai.partNum {
                AsyncImage(url: URL(string: "https://brickarchitect.com/content/parts-large/\(partNum).png")) { img in
                    img.resizable().scaledToFit()
                } placeholder: { EmptyView() }
                .frame(maxHeight: 120)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Manual override
            VStack(alignment: .leading, spacing: 8) {
                Text("Override Part Number").font(.caption).foregroundColor(.secondary)
                HStack {
                    TextField("e.g. 3001", text: $manualPartNum)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                    Button("Look Up") {
                        Task { await relookup(partNum: manualPartNum) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(manualPartNum.isEmpty || isLookingUp)
                }

                if isLookingUp {
                    HStack { ProgressView(); Text("Looking up…").font(.caption) }
                }

                if let lr = lookupResult {
                    if lr.foundOnBrickarchitect {
                        lookupResultCard(lr)
                    } else {
                        Text("Part not found on Brick Architect.")
                            .font(.caption).foregroundColor(.red)
                    }
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func lookupResultCard(_ lr: LookupResponse) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                AsyncImage(url: URL(string: "https://brickarchitect.com/content/parts-large/\(lr.partNum).png")) { img in
                    img.resizable().scaledToFit()
                } placeholder: { Color(.systemGray5) }
                .frame(width: 60, height: 60)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    Text(lr.name ?? "Unknown").font(.subheadline).fontWeight(.bold)
                    Text("#\(lr.partNum)").font(.caption).foregroundColor(.secondary)
                    if let existing = lr.existing, let loc = existing.locationDisplay {
                        Text(loc).font(.caption).foregroundColor(.green)
                    } else {
                        Text("Not in catalog").font(.caption).foregroundColor(.orange)
                    }
                }
            }
            Button("Use This Part") { applyLookup(lr) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(10)
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func confidenceBadge(_ conf: Double) -> some View {
        let pct = Int(conf * 100)
        let color: Color = conf >= 0.8 ? .green : conf >= 0.5 ? .orange : .red
        return Text("\(pct)%")
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .clipShape(Capsule())
    }

    // MARK: - Actions

    private func relookup(partNum: String) async {
        guard !partNum.isEmpty else { return }
        isLookingUp = true
        lookupResult = nil
        do {
            lookupResult = try await api.lookupPart(partNum)
        } catch {}
        isLookingUp = false
    }

    private func applyLookup(_ lr: LookupResponse) {
        manualPartNum = lr.partNum
        lookupResult = nil
        if var current = result {
            // Patch the AI result with the looked-up part number
            let updatedAI = AIResult(
                partNum: lr.partNum,
                name: lr.name ?? current.ai.name,
                category: current.ai.category,
                color: current.ai.color,
                description: current.ai.description,
                confidence: current.ai.confidence
            )
            result = IdentifyResponse(ai: updatedAI, existing: lr.existing, location: nil)
        }
    }
}
