import SwiftUI

struct EditPartSheet: View {
    @EnvironmentObject var api: APIService
    @Environment(\.dismiss) var dismiss

    let part: Part
    let onSaved: (Part?) -> Void

    @State private var partName: String
    @State private var category: String
    @State private var notes: String
    @State private var drawers: [Drawer] = []
    @State private var selectedDrawerID: String?
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showDeleteConfirm = false

    init(part: Part, onSaved: @escaping (Part?) -> Void) {
        self.part = part
        self.onSaved = onSaved
        _partName = State(initialValue: part.partName)
        _category = State(initialValue: part.category ?? "")
        _notes = State(initialValue: part.notes ?? "")
        _selectedDrawerID = State(initialValue: part.drawerID)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AsyncImage(url: part.brickArchitectImageURL) { img in
                        img.resizable().scaledToFit()
                    } placeholder: { EmptyView() }
                    .frame(maxHeight: 120)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                Section("Part Details") {
                    LabeledContent("Part Number", value: part.partNum)
                    TextField("Part Name", text: $partName)
                    TextField("Category", text: $category)
                    TextField("Notes", text: $notes)
                }

                Section("Drawer") {
                    if let loc = part.locationDisplay {
                        Text("Current: \(loc)").foregroundColor(.secondary).font(.caption)
                    }
                    ForEach(drawers) { drawer in
                        Button(action: { selectedDrawerID = drawer.id }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(drawer.displayLabel).fontWeight(.semibold)
                                    if let label = drawer.label {
                                        Text(label).font(.caption).foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                if selectedDrawerID == drawer.id {
                                    Image(systemName: "checkmark").foregroundColor(.accentColor)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section {
                    Button("Delete Part", role: .destructive) { showDeleteConfirm = true }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundColor(.red).font(.caption)
                    }
                }
            }
            .navigationTitle("Edit Part")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(partName.isEmpty || isSaving)
                }
            }
            .task { drawers = (try? await api.listDrawers()) ?? [] }
            .confirmationDialog("Delete \(part.partNum)?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { Task { await delete() } }
            }
        }
    }

    private func save() async {
        isSaving = true
        do {
            let updated = try await api.updatePart(
                partNum: part.partNum,
                partName: partName,
                category: category.isEmpty ? nil : category,
                drawerID: selectedDrawerID,
                notes: notes.isEmpty ? nil : notes
            )
            onSaved(updated)
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }

    private func delete() async {
        do {
            _ = try await api.updatePart(partNum: part.partNum, drawerID: nil)
            onSaved(nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
