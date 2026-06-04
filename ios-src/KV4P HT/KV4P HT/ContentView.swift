import SwiftUI

struct ContentView: View {
    @State private var store = RadioStore()
    @State private var selectedTab: Tab = .voice

    enum Tab: String, CaseIterable {
        case voice, aprs, map, memories, more
        var label: String {
            switch self {
            case .voice:    return "Voice"
            case .aprs:     return "APRS"
            case .map:      return "Map"
            case .memories: return "Memories"
            case .more:     return "More"
            }
        }
        var icon: String {
            switch self {
            case .voice:    return "waveform"
            case .aprs:     return "message"
            case .map:      return "map"
            case .memories: return "star"
            case .more:     return "ellipsis.circle"
            }
        }
        var selectedIcon: String {
            switch self {
            case .voice:    return "waveform"
            case .aprs:     return "message.fill"
            case .map:      return "map.fill"
            case .memories: return "star.fill"
            case .more:     return "ellipsis.circle.fill"
            }
        }
    }

    private var theme: AppTheme { store.theme }

    var body: some View {
        tabContent
            .safeAreaInset(edge: .bottom, spacing: 0) {
                KVTabBar(tabs: Tab.allCases, selected: $selectedTab)
                    .environment(\.theme, theme)
            }
            .environment(\.theme, theme)
            .preferredColorScheme(theme.isDark ? .dark : .light)
            .tint(theme.accent)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .voice:
            VoiceView(store: store)
        case .aprs:
            NavigationStack {
                APRSView(store: store)
            }
        case .map:
            APRSMapView(store: store)
        case .memories:
            NavigationStack {
                MemoriesView(store: store)
            }
        case .more:
            MoreView(store: store)
        }
    }
}

// MARK: - Custom Tab Bar

struct KVTabBar: View {
    @Environment(\.theme) var t
    var tabs: [ContentView.Tab]
    @Binding var selected: ContentView.Tab

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(t.hairline)
                .frame(height: 0.5)
            HStack(spacing: 0) {
                ForEach(tabs, id: \.rawValue) { tab in
                    let on = tab == selected
                    Button {
                        selected = tab
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: on ? tab.selectedIcon : tab.icon)
                                .font(.system(size: 22, weight: on ? .semibold : .regular))
                                .foregroundStyle(on ? t.accent : t.label2)
                            Text(tab.label)
                                .font(.system(size: 10.5, weight: on ? .semibold : .medium))
                                .foregroundStyle(on ? t.accent : t.label2)
                                .tracking(0.1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 9)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(t.chrome)
            .background(.ultraThinMaterial)
            .padding(.bottom, 22)  // home indicator clearance
        }
    }
}

#Preview("Dark") {
    ContentView()
}

#Preview("Light") {
    ContentView()
        .onAppear {
            // Preview helper — set via store after init
        }
}
