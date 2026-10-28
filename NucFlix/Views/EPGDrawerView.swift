import SwiftUI

struct EPGDrawerView: View {
    @Environment(AppState.self) var appState
    @Environment(\.dismiss) private var dismiss

    let channelName: String
    let streamId: Int

    private var listings: [XtreamEPGItem] {
        appState.epgCache[streamId] ?? []
    }

    var body: some View {
        NavigationStack {
            Group {
                if listings.isEmpty {
                    ContentUnavailableView(
                        "No TV Guide Data",
                        systemImage: "calendar.badge.exclamationmark",
                        description: Text("This channel does not currently publish EPG program listings.")
                    )
                } else {
                    List(listings) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                if item.isNowPlaying {
                                    Text("LIVE NOW")
                                        .font(.system(size: 10, weight: .heavy))
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2)
                                        .background(.cyan, in: Capsule())
                                        .foregroundStyle(.black)
                                }
                                Text(item.formattedTimeRange)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(item.isNowPlaying ? .cyan : .secondary)
                                Spacer()
                            }

                            Text(item.title)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)

                            if !item.descriptionText.isEmpty {
                                Text(item.descriptionText)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.75))
                                    .lineLimit(4)
                            }

                            if item.isNowPlaying {
                                ProgressView(value: item.progress)
                                    .tint(.cyan)
                                    .padding(.top, 4)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle(channelName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        appState.loadEPGIfNeeded(for: streamId, force: true)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                appState.loadEPGIfNeeded(for: streamId)
            }
        }
        .preferredColorScheme(.dark)
    }
}
