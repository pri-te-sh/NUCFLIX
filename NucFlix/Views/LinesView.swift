import SwiftUI

/// The household's Xtream Codes lines. Every profile (and paired TV) can play through any of them;
/// this device remembers which one it uses.
struct LinesView: View {
    @Environment(CloudAccount.self) var cloud
    @Environment(\.dismiss) private var dismiss
    @State private var formTarget: FormTarget?
    @State private var lineToDelete: CloudLine?

    private struct FormTarget: Identifiable {
        let line: CloudLine?
        var id: String { line?.id ?? "new" }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(cloud.lines) { line in
                        HStack(spacing: 14) {
                            Image(systemName: cloud.activeLine?.id == line.id ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(cloud.activeLine?.id == line.id ? AppTheme.netflixRed : .white.opacity(0.35))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(line.name).font(.body.weight(.semibold))
                                Text("\(line.username) • \(URL(string: line.serverURL)?.host ?? line.serverURL)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button {
                                formTarget = FormTarget(line: line)
                            } label: {
                                Image(systemName: "pencil").foregroundStyle(.white.opacity(0.7))
                            }
                            .buttonStyle(.borderless)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { cloud.selectLine(line.id) }
                        .swipeActions {
                            Button("Delete", role: .destructive) { lineToDelete = line }
                        }
                    }
                } footer: {
                    Text("Lines are saved in your NucFlix account (never on this iPhone) and shared by every profile and your TVs. Tap one to watch through it on this iPhone.")
                }

                Section {
                    Button {
                        formTarget = FormTarget(line: nil)
                    } label: {
                        Label("Add IPTV Line", systemImage: "plus")
                    }
                }
            }
            .navigationTitle("IPTV Lines")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(item: $formTarget) { target in
                LineFormView(editing: target.line)
                    .environment(cloud)
            }
            .confirmationDialog("Delete \(lineToDelete?.name ?? "")?", isPresented: Binding(
                get: { lineToDelete != nil }, set: { if !$0 { lineToDelete = nil } }
            ), titleVisibility: .visible) {
                Button("Delete Line", role: .destructive) {
                    guard let line = lineToDelete else { return }
                    Task { await cloud.deleteLine(line) }
                }
            } message: {
                Text("Profiles and TVs using this line will need another one to keep watching.")
            }
        }
        .preferredColorScheme(.dark)
    }
}
