import SwiftUI

struct DrawersView: View {
    @EnvironmentObject var api: APIService

    @State private var drawers: [Drawer] = []
    @State private var selectedDrawer: Drawer?
    @State private var showAddDrawer = false

    // Group by cabinet
    private var byCabinet: [(Int, [Drawer])] {
        var dict: [Int: [Drawer]] = [:]
        for d in drawers { dict[d.cabinet, default: []].append(d) }
        return dict.sorted { $0.key < $1.key }
    }

    var body: some View {
        NavigationStack {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(byCabinet, id: \.0) { cabinet, cabinetDrawers in
                        CabinetColumn(
                            cabinet: cabinet,
                            drawers: cabinetDrawers,
                            onTap: { selectedDrawer = $0 },
                            onAddDrawer: { cab, row, col in
                                showAddDrawer = true
                            }
                        )
                    }

                    if drawers.isEmpty {
                        ContentUnavailableView(
                            "No Drawers",
                            systemImage: "square.grid.3x3",
                            description: Text("Tap + to add your first drawer.")
                        )
                        .frame(width: 300)
                    }
                }
                .padding()
            }
            .navigationTitle("Drawers")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { showAddDrawer = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .task { await loadDrawers() }
            .sheet(item: $selectedDrawer) { drawer in
                DrawerDetailSheet(drawer: drawer, onDismiss: {
                    selectedDrawer = nil
                    Task { await loadDrawers() }
                })
            }
            .sheet(isPresented: $showAddDrawer) {
                AddDrawerSheet(onSaved: {
                    showAddDrawer = false
                    Task { await loadDrawers() }
                })
            }
        }
    }

    private func loadDrawers() async {
        drawers = (try? await api.listDrawers()) ?? []
    }
}

// MARK: - Cabinet column

struct CabinetColumn: View {
    let cabinet: Int
    let drawers: [Drawer]
    let onTap: (Drawer) -> Void
    let onAddDrawer: (Int, String, Int) -> Void

    private var rows: [String] {
        Array(Set(drawers.map { $0.row })).sorted()
    }

    private var maxCol: Int {
        drawers.map { $0.col }.max() ?? 1
    }

    private var existing: [String: Drawer] {
        Dictionary(uniqueKeysWithValues: drawers.map { ("\($0.row)\($0.col)", $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Cabinet \(cabinet)")
                .font(.caption.bold())
                .foregroundColor(.secondary)
                .textCase(.uppercase)

            ForEach(rows, id: \.self) { row in
                VStack(alignment: .leading, spacing: 3) {
                    Text("Row \(row)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)

                    HStack(spacing: 4) {
                        ForEach(1...maxCol, id: \.self) { col in
                            if let d = existing["\(row)\(col)"] {
                                DrawerTile(drawer: d, onTap: { onTap(d) })
                            } else {
                                EmptyDrawerTile(label: "\(row)\(col)") {
                                    onAddDrawer(cabinet, row, col)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Drawer tile

struct DrawerTile: View {
    let drawer: Drawer
    let onTap: () -> Void

    private var isOccupied: Bool { drawer.partCount > 0 }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 2) {
                Text("\(drawer.row)\(drawer.col)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(isOccupied ? .red : .green)

                if let url = drawer.firstPartImageURL {
                    AsyncImage(url: url) { img in
                        img.resizable().scaledToFit()
                    } placeholder: {
                        Color.clear
                    }
                    .frame(width: 30, height: 30)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                } else {
                    Color.clear.frame(width: 30, height: 30)
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 2)
            .frame(minWidth: 38)
            .background(isOccupied ? Color.red.opacity(0.12) : Color.green.opacity(0.10))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(isOccupied ? Color.red.opacity(0.35) : Color.green.opacity(0.30), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }
}

struct EmptyDrawerTile: View {
    let label: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 2) {
                Text(label)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.green.opacity(0.7))
                Color.clear.frame(width: 30, height: 30)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 2)
            .frame(minWidth: 38)
            .background(Color.green.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.green.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4]))
            )
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Drawer detail sheet

struct DrawerDetailSheet: View {
    @EnvironmentObject var api: APIService
    let drawer: Drawer
    let onDismiss: () -> Void

    @State private var drawerWithParts: DrawerWithParts?
    @State private var selectedPart: Part?

    var body: some View {
        NavigationStack {
            Group {
                if let dwp = drawerWithParts {
                    if dwp.parts.isEmpty {
                        ContentUnavailableView("Empty Drawer", systemImage: "tray")
                    } else {
                        List(dwp.parts) { part in
                            Button(action: { selectedPart = part }) {
                                PartRow(part: part)
                            }
                            .buttonStyle(.plain)
                        }
                        .listStyle(.plain)
                    }
                } else {
                    ProgressView("Loading…")
                }
            }
            .navigationTitle("\(drawer.displayLabel) — \(drawerWithParts?.parts.count ?? 0) parts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDismiss() }
                }
            }
            .task {
                drawerWithParts = try? await api.getDrawerParts(drawerID: drawer.id)
            }
            .sheet(item: $selectedPart) { part in
                EditPartSheet(part: part) { _ in
                    Task {
                        selectedPart = nil
                        drawerWithParts = try? await api.getDrawerParts(drawerID: drawer.id)
                    }
                }
            }
        }
    }
}

// MARK: - Add drawer sheet

struct AddDrawerSheet: View {
    @EnvironmentObject var api: APIService
    let onSaved: () -> Void

    @State private var cabinet = "1"
    @State private var row = "A"
    @State private var col = "1"
    @State private var label = ""
    @State private var notes = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Location") {
                    HStack {
                        TextField("Cabinet", text: $cabinet).keyboardType(.numberPad)
                        TextField("Row", text: $row)
                        TextField("Col", text: $col).keyboardType(.numberPad)
                    }
                }
                Section("Optional") {
                    TextField("Label", text: $label)
                    TextField("Notes", text: $notes)
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundColor(.red).font(.caption) }
                }
            }
            .navigationTitle("Add Drawer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onSaved() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await save() } }
                        .disabled(cabinet.isEmpty || row.isEmpty || col.isEmpty || isSaving)
                }
            }
        }
    }

    private func save() async {
        guard let cab = Int(cabinet), let c = Int(col), !row.isEmpty else { return }
        isSaving = true
        do {
            _ = try await api.createDrawer(
                cabinet: cab, row: row.uppercased(), col: c,
                label: label.isEmpty ? nil : label,
                notes: notes.isEmpty ? nil : notes
            )
            onSaved()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}
