import SwiftUI

struct CaptureModePicker: View {
    @Binding var selection: RecordingCaptureMode
    var isDisabled = false
    var accessibilityIdentifier: String

    var body: some View {
        Picker("Sources", selection: $selection) {
            ForEach(RecordingCaptureMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .disabled(isDisabled)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
