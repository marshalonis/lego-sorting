import SwiftUI

struct BrowseView: View {
    @EnvironmentObject var api: APIService

    @State private var parts: [Part] = []
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var searchTask: Task<Void, Never>?
    @State private var selectedPart: Part?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading…")
                } else if parts.isEmpty {
                    ContentUnavailableView(
                        searchText.isEmpty ? "No Parts" : "No Results",
                        systemImage: "magnifyingglass",
                        description: Text(searchText.isEmpty ? "Add parts using the Identify tab." : "Try different keywords.")
                    )
                } else {
                    List(parts) { part in
                        Button(action: { selectedPart = part }) {
                            PartRow(part: part)
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Browse Parts")
            .searchable(text: $searchText, prompt: "Search by name, number, category…")
            .onChange(of: searchText) { _, q in
                searchTask?.cancel()
                searchTask = Task {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard !Task.isCancelled else { return }
                    await loadParts(query: q)
                }
            }
            .task { await loadParts() }
            .sheet(item: $selectedPart) { part in
                EditPartSheet(part: part) { updated in
                    selectedPart = nil
                    Task { await loadParts(query: searchText) }
                }
            }
        }
    }

    private func loadParts(query: String = "") async {
        isLoading = parts.isEmpty
        parts = (try? await api.listParts(query: query)) ?? []
        isLoading = false
    }
}

struct PartRow: View {
    let part: Part

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: part.brickArchitectImageURL) { img in
                img.resizable().scaledToFit()
            } placeholder: {
                Color(.systemGray5)
            }
            .frame(width: 44, height: 44)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(part.partName).font(.subheadline).fontWeight(.semibold)
                Text("#\(part.partNum)\(part.category.map { " · \($0)" } ?? "")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if let loc = part.locationDisplay {
                Text(loc)
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.1))
                    .foregroundColor(.accentColor)
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 4)
    }
}
