import SwiftUI

struct LibraryView: View {
    @Bindable var store: WiretapStore

    var body: some View {
        NavigationSplitView {
            RecordingSidebar(store: store)
                .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 420)
        } detail: {
            if let recording = store.selectedRecording {
                RecordingDetailView(recording: recording, store: store)
            } else {
                EmptyLibraryView(isFiltering: !store.searchText.isEmpty)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    store.isOnboardingPresented = true
                } label: {
                    Label("Permissions", systemImage: "lock.shield")
                }
                .help("Review capture permissions")

                RecordingControlView(store: store, style: .toolbar)
            }
        }
        .sheet(isPresented: $store.isOnboardingPresented) {
            OnboardingView(store: store)
        }
        .task(id: store.isRecording) {
            while store.isRecording {
                store.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

private struct RecordingSidebar: View {
    @Bindable var store: WiretapStore

    var body: some View {
        VStack(spacing: 0) {
            LibraryHeader(recordingCount: store.recordings.count)

            if store.filteredRecordings.isEmpty {
                EmptyLibraryView(isFiltering: !store.searchText.isEmpty)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $store.selectedRecordingID) {
                    ForEach(store.filteredRecordings) { recording in
                        RecordingRowView(recording: recording)
                            .tag(recording.id)
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .searchable(text: $store.searchText, prompt: "Search recordings")
    }
}

private struct LibraryHeader: View {
    let recordingCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Library", systemImage: "rectangle.stack.fill")
                    .font(.title2.weight(.semibold))

                Spacer()

                Text("\(recordingCount)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text("Local recordings")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }
}

#Preview {
    LibraryView(store: .preview)
        .frame(width: 1080, height: 720)
}
