import SwiftUI

/// Pair a Fire TV: enter the code it shows. Also lists the paired TVs so one can be removed.
struct PairTVView: View {
    @Environment(CloudAccount.self) var cloud
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var pairedName: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("On the TV, open NucFlix — it shows an 8-character code. Enter it here to give the TV your profiles, IPTV lines, My List and Continue Watching.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        TextField("K7Q2M9XD", text: $code)
                            .font(.system(size: 34, weight: .bold, design: .monospaced))
                            .multilineTextAlignment(.center)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .focused($focused)
                            .submitLabel(.go)
                            .onSubmit(pair)
                            .tracking(6)
                            // The typed text is never rewritten (doing so while typing dropped characters);
                            // it's normalized when checked and submitted instead.
                        Button(action: pair) {
                            HStack {
                                Spacer()
                                if cloud.isBusy { ProgressView().tint(.white) }
                                Text("Pair TV").font(.headline)
                                Spacer()
                            }
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.netflixRed)
                        .disabled(normalizedCode.count != 8 || cloud.isBusy)
                    }
                    .padding(.vertical, 6)
                }
                if let error = cloud.authError {
                    Section { Text(error).foregroundStyle(AppTheme.primaryRed) }
                } else if let pairedName {
                    Section {
                        Label("\(pairedName) is paired — pick a profile on the TV to start watching.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(AppTheme.matchGreen)
                    }
                }
                Section("Paired TVs") {
                    if cloud.pairedTVs.isEmpty {
                        Text("No TVs yet").foregroundStyle(.secondary)
                    }
                    ForEach(cloud.pairedTVs) { tv in
                        HStack {
                            Image(systemName: "tv")
                            VStack(alignment: .leading) {
                                Text(tv.name)
                                if let at = tv.pairedAt {
                                    Text("Paired \(at.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .swipeActions {
                            Button("Remove", role: .destructive) { Task { await cloud.removeTV(tv) } }
                        }
                    }
                }
            }
            .navigationTitle("Pair a TV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear {
                cloud.authError = nil
                focused = true
            }
        }
        .preferredColorScheme(.dark)
    }

    private var normalizedCode: String { code.uppercased().filter { $0.isLetter || $0.isNumber } }

    private func pair() {
        pairedName = nil
        let entered = normalizedCode
        Task {
            if let name = await cloud.approvePairing(code: entered) {
                pairedName = name
                code = ""
            }
        }
    }
}
