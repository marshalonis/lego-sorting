import SwiftUI

struct DrawerPickerSheet: View {
    @EnvironmentObject var api: APIService
    @Environment(\.dismiss) var dismiss

    let ai: AIResult
    let manualPartNum: String
    let onSaved: (IdentifyResponse) -> Void

    @State private var drawers: [Drawer] = []
    @State private var selectedDrawerID: String?
    @State private var partNum: String
    @State private var partName: String
    @State private var notes = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    // New drawer fields
    @State private var newCabinet = "1"
    @State private var newRow = "A"
    @State private var newCol = "1"
    @State private var newLabel = ""
    @State private var showNewDrawer = false

    init(ai: AIResult, manualPartNum: String, onSaved: @escaping (IdentifyResponse) -> Void) {
        self.ai = ai
        self.manualPartNum = manualPartNum
        self.onSaved = onSaved
        _partNum = State(initialValue: manualPartNum.isEmpty ? ai.partNum ?? "" : manualPartNum)
        _partName = State(initialValue: ai.name)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Part Details") {
                    TextField("Part Number", text: $partNum)
                        .autocorrectionDisabled()
                    TextField("Part Name", text: $partName)
                    TextField("Notes (optional)", text: $notes)
                }

                Section("Select Drawer") {
                    if drawers.isEmpty {
                        Text("No drawers yet. Create one below.")
                            .foregroundColor(.secondary)
                    } else {
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
                                    Text("\(drawer.partCount) parts")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    if selectedDrawerID == drawer.id {
                                        Image(systemName: "checkmark").foregroundColor(.accentColor)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section {
                    DisclosureGroup("Create New Drawer", isExpanded: $showNewDrawer) {
                        HStack {
                            TextField("Cabinet", text: $newCabinet)
                                .keyboardType(.numberPad)
                                .frame(maxWidth: 80)
                            TextField("Row", text: $newRow)
                                .frame(maxWidth: 60)
                            TextField("Col", text: $newCol)
                                .keyboardType(.numberPad)
                                .frame(maxWidth: 60)
                        }
                        TextField("Label (optional)", text: $newLabel)
                        Button("Create & Select") { Task { await createDrawer() } }
                            .buttonStyle(.borderedProminent)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundColor(.red).font(.caption)
                    }
                }
            }
            .navigationTitle("Assign to Drawer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(partNum.isEmpty || partName.isEmpty || selectedDrawerID == nil || isSaving)
                }
            }
            .task { await loadDrawers() }
        }
    }

    private func loadDrawers() async {
        drawers = (try? await api.listDrawers()) ?? []
    }

    private func createDrawer() async {
        guard let cab = Int(newCabinet), let col = Int(newCol), !newRow.isEmpty else { return }
        do {
            let drawer = try await api.createDrawer(
                cabinet: cab, row: newRow.uppercased(), col: col,
                label: newLabel.isEmpty ? nil : newLabel, notes: nil
            )
            drawers = (try? await api.listDrawers()) ?? []
            selectedDrawerID = drawer.id
            showNewDrawer = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save() async {
        guard let drawerID = selectedDrawerID, !partNum.isEmpty, !partName.isEmpty else { return }
        isSaving = true
        do {
            let part = try await api.createPart(
                partNum: partNum,
                partName: partName,
                category: ai.category,
                drawerID: drawerID,
                notes: notes.isEmpty ? nil : notes,
                aiDescription: nil
            )
            let drawer = drawers.first { $0.id == drawerID }
            let location = drawer.map { d in
                LocationInfo(
                    drawerID: d.id,
                    cabinet: d.cabinet,
                    row: d.row,
                    col: d.col,
                    display: "Cabinet \(d.cabinet) · \(d.row)\(d.col)"
                )
            }
            let updatedResponse = IdentifyResponse(ai: ai, existing: part, location: location)
            onSaved(updatedResponse)
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}
