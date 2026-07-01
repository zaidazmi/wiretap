import SwiftUI

struct EmptyLibraryView: View {
    let isFiltering: Bool

    var body: some View {
        ContentUnavailableView {
            Label(isFiltering ? "No Matches" : "No Recordings", systemImage: isFiltering ? "magnifyingglass" : "tray")
        } description: {
            Text(isFiltering ? "Try a different search." : "Recordings will appear here after capture is enabled.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    EmptyLibraryView(isFiltering: false)
        .frame(width: 420, height: 360)
}
