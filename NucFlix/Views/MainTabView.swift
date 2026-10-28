import SwiftUI

enum MainTab: Int, Hashable {
    case home = 0
    case liveTV = 1
    case movies = 2
    case series = 3
    case search = 4
}

struct MainTabView: View {
    @Environment(AppState.self) var appState
    @State private var selectedTab: MainTab = .home

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView(selectedTab: $selectedTab)
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }
                .tag(MainTab.home)

            LiveTVView()
                .tabItem {
                    Label("Live TV", systemImage: "dot.radiowaves.left.and.right")
                }
                .tag(MainTab.liveTV)

            MoviesView()
                .tabItem {
                    Label("Movies", systemImage: "film.stack.fill")
                }
                .tag(MainTab.movies)

            SeriesView()
                .tabItem {
                    Label("Series", systemImage: "tv.inset.filled")
                }
                .tag(MainTab.series)

            SearchView()
                .tabItem {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .tag(MainTab.search)
        }
        .tint(.white)
    }
}
