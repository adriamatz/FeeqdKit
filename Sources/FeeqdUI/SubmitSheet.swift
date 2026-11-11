import FeeqdCore
import SwiftUI

/// A new request. Says "sent", never "published": the backend answers `202 queued`, and the
/// board may hold it for moderation.
struct SubmitSheet: View {
    @ObservedObject var store: BoardStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.feeqdStrings) private var strings
    @Environment(\.feeqdTheme) private var theme

    @State private var title = ""
    @State private var details = ""
    @State private var similar: [SimilarEntry] = []
    @State private var sending = false
    @State private var sent = false
    /// It could not go out and was kept to be sent later.
    @State private var kept = false
    @State private var error: FeeqdError?
    @State private var confirmingDiscard = false

    /// Something typed and not sent yet: closing asks first, by Cancel or by swiping down.
    private var hasDraft: Bool {
        !sent && !(title.feeqdTrimmed.isEmpty && details.feeqdTrimmed.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Group {
                if sent { sentView } else { form }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.background.ignoresSafeArea())
            .navigationTitle(strings(.submitTitle))
            .feeqdInlineTitle(theme)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(sent ? strings(.submitDone) : strings(.submitCancel)) {
                        if hasDraft { confirmingDiscard = true } else { dismiss() }
                    }
                }
                if !sent {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(strings(.submitSend)) { Task { await send() } }
                            .disabled(title.feeqdTrimmed.isEmpty || sending)
                    }
                }
            }
            .confirmationDialog(strings(.submitDiscardTitle), isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button(strings(.submitDiscardConfirm), role: .destructive) { dismiss() }
                Button(strings(.submitDiscardKeep), role: .cancel) {}
            }
        }
        // A draft can't be swiped away: Cancel asks before it goes.
        .interactiveDismissDisabled(hasDraft)
        // Possible duplicates while typing: advice, never a block.
        .task(id: title) {
            let text = title.feeqdTrimmed
            guard text.count >= 4 else {
                similar = []
                return
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            similar = Array(await store.similar(to: text).prefix(3))
        }
    }

    private var form: some View {
        Form {
            Section {
                TextField(strings(.submitTitlePlaceholder), text: $title)
                TextField(strings(.submitDescriptionPlaceholder), text: $details, axis: .vertical)
                    .lineLimit(3...8)
            }
            .listRowBackground(theme.surface)
            if !similar.isEmpty {
                Section(strings(.submitSimilar)) {
                    ForEach(similar) { entry in
                        Text(entry.title).foregroundStyle(theme.textSecondary)
                    }
                }
                .listRowBackground(theme.surface)
            }
            if let error {
                Section {
                    Text(error == .quotaExceeded ? strings(.submitQuotaExceeded) : feeqdMessage(for: error, strings: strings))
                        .foregroundStyle(.red)
                }
                .listRowBackground(theme.surface)
            }
        }
        // The fields on the theme's surface, the screen behind them on its background.
        .scrollContentBackground(.hidden)
        .disabled(sending)
    }

    private var sentView: some View {
        VStack(spacing: 12) {
            Image(systemName: kept ? "clock.fill" : "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(theme.primary)
            Text(strings(kept ? .submitKeptTitle : .submitSentTitle))
                .font(.title3.weight(.semibold))
            Text(strings(kept ? .submitKeptMessage : .submitSentMessage))
                .multilineTextAlignment(.center)
                .foregroundStyle(theme.textSecondary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func send() async {
        // Two taps before the button redraws as disabled would send the request twice.
        guard !sending else { return }
        sending = true
        error = nil
        defer { sending = false }
        do {
            let receipt = try await store.submit(title: title.feeqdTrimmed, description: details.feeqdTrimmed)
            kept = receipt == nil
            sent = true
            if !kept { Task { await store.reloadAfterSubmit() } }
        } catch {
            self.error = FeeqdError.wrap(error)
        }
    }
}
