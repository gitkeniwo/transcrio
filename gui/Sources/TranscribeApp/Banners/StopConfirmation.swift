import SwiftUI

/// Quit confirmation while a file runs. Stopping a single file needs none: the next one starts
/// and the stopped file can be retried.
struct StopConfirmation: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .alert("Quit while transcribing?", isPresented: $model.showQuitConfirmation) {
                Button("Keep Going", role: .cancel) { model.confirmQuit(false) }
                Button("Stop and Quit", role: .destructive) { model.confirmQuit(true) }
            } message: {
                Text(Self.message(waiting: model.queue.upNext.count))
            }
    }

    static func message(waiting: Int) -> String {
        let rest = waiting == 0 ? "" : waiting == 1 ? " 1 file in Up next goes back to Ready." : " \(waiting) files in Up next go back to Ready."
        return "The current file will stop." + rest + " Finished files are kept."
    }
}

extension View {
    func stopConfirmation() -> some View { modifier(StopConfirmation()) }
}
