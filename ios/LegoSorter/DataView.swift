import SwiftUI
import UniformTypeIdentifiers

struct DataView: View {
    @EnvironmentObject var auth: AuthService
    @EnvironmentObject var api: APIService

    @State private var models: ModelsResponse?
    @State private var catalogStatus: CatalogStatus?
    @State private var partCount = 0
    @State private var drawerCount = 0

    @State private var isLoadingCatalog = false
    @State private var catalogMessage: String?
    @State private var catalogMessageIsError = false

    @State private var isExporting = false
    @State private var exportedData: Data?
    @State private var showExporter = false

    @State private var showImporter = false
    @State private var importMessage: String?
    @State private var importMessageIsError = false

    var body: some View {
        NavigationStack {
            Form {
                // AI Model
                Section("AI Model") {
                    if let models {
                        Text("Provider: AWS Bedrock").foregroundColor(.secondary).font(.caption)
                        Picker("Model", selection: Binding(
                            get: { models.active },
                            set: { newID in Task { await setModel(newID) } }
                        )) {
                            ForEach(models.available) { model in
                                Text(model.label).tag(model.id)
                            }
                        }
                        .pickerStyle(.menu)
                    } else {
                        ProgressView()
                    }
                }

                // Stats
                Section("Catalog") {
                    LabeledContent("Parts cataloged", value: "\(partCount)")
                    LabeledContent("Drawers", value: "\(drawerCount)")
                    if let cs = catalogStatus {
                        LabeledContent("Parts database", value: cs.partsInCatalog == 0 ? "Not loaded" : "\(cs.partsInCatalog.formatted()) parts")
                    }
                }

                // Parts catalog download
                Section {
                    Button(isLoadingCatalog ? "Downloading…" : "Download Parts Catalog") {
                        Task { await downloadCatalog() }
                    }
                    .disabled(isLoadingCatalog)

                    if let msg = catalogMessage {
                        Text(msg)
                            .font(.caption)
                            .foregroundColor(catalogMessageIsError ? .red : .green)
                    }
                } header: {
                    Text("Parts Database")
                } footer: {
                    Text("Downloads the full Rebrickable parts database (~60k parts) to enable name search on the Identify tab.")
                }

                // Export
                Section("Export") {
                    Button(isExporting ? "Exporting…" : "Export Catalog") {
                        Task { await exportCatalog() }
                    }
                    .disabled(isExporting)
                }

                // Import
                Section("Import") {
                    Button("Import Catalog") { showImporter = true }

                    if let msg = importMessage {
                        Text(msg)
                            .font(.caption)
                            .foregroundColor(importMessageIsError ? .red : .green)
                    }
                }

                // Account
                Section("Account") {
                    Button("Sign Out", role: .destructive) { auth.logout() }
                }
            }
            .navigationTitle("Data")
            .task { await loadAll() }
            .fileExporter(
                isPresented: $showExporter,
                document: JSONDocument(data: exportedData ?? Data()),
                contentType: .json,
                defaultFilename: "lego-catalog"
            ) { _ in exportedData = nil }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
                Task { await handleImport(result) }
            }
        }
    }

    private func loadAll() async {
        async let m = try? api.listModels()
        async let cs = try? api.catalogStatus()
        async let parts = try? api.listParts()
        async let drawers = try? api.listDrawers()

        models = await m
        catalogStatus = await cs
        partCount = await parts?.count ?? 0
        drawerCount = await drawers?.count ?? 0
    }

    private func setModel(_ id: String) async {
        try? await api.setModel(id)
        models = try? await api.listModels()
    }

    private func downloadCatalog() async {
        isLoadingCatalog = true
        catalogMessage = nil
        do {
            let count = try await api.loadCatalog()
            catalogMessage = "Loaded \(count.formatted()) parts."
            catalogMessageIsError = false
            catalogStatus = try? await api.catalogStatus()
        } catch {
            catalogMessage = error.localizedDescription
            catalogMessageIsError = true
        }
        isLoadingCatalog = false
    }

    private func exportCatalog() async {
        isExporting = true
        do {
            exportedData = try await api.exportCatalog()
            showExporter = true
        } catch {}
        isExporting = false
    }

    private func handleImport(_ result: Result<URL, Error>) async {
        importMessage = nil
        do {
            let url = try result.get()
            guard url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }
            let data = try Data(contentsOf: url)
            let (parts, drawers) = try await api.importCatalog(data)
            importMessage = "Imported \(parts) parts, \(drawers) drawers."
            importMessageIsError = false
            await loadAll()
        } catch {
            importMessage = error.localizedDescription
            importMessageIsError = true
        }
    }
}

// Required for fileExporter
struct JSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
