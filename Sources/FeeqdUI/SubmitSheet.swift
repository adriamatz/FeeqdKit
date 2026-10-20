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
    @State private var error: FeeqdError?

    var body: some View {
        NavigationStack {
            Group {
                if sent { sentView } else { form }
            }
            .navigationTitle(strings(.submitTitle))
            .feeqdInlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(sent ? strings(.submitDone) : strings(.submitCancel)) { dismiss() }
                }
                if !sent {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(strings(.submitSend)) { Task { await send() } }
                            .disabled(title.feeqdTrimmed.isEmpty || sending)
                    }
                }
            }
        }
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
            if !similar.isEmpty {
                Section(strings(.submitSimilar)) {
                    ForEach(similar) { entry in
                        Text(entry.title).foregroundStyle(theme.textSecondary)
                    }
                }
            }
            if let error {
                Section {
                    Text(error == .quotaExceeded ? strings(.submitQuotaExceeded) : feeqdMessage(for: error, strings: strings))
                        .foregroundStyle(.red)
                }
            }
        }
        .disabled(sending)
    }

    private var sentView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(theme.primary)
            Text(strings(.submitSentTitle))
                .font(.title3.weight(.semibold))
            Text(strings(.submitSentMessage))
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
            _ = try await store.submit(title: title.feeqdTrimmed, description: details.feeqdTrimmed)
            sent = true
            Task { await store.reloadAfterSubmit() }
        } catch {
            self.error = FeeqdError.wrap(error)
        }
    }
}
