import FeeqdCore
import SwiftUI

/// The vote control: a solid tile with the count, filled with the vote colour once voted, so
/// what you backed reads at a glance down a list. Labelled for VoiceOver, its own tap target.
struct VoteButton: View {
    let count: Int
    let voted: Bool
    let showsCount: Bool
    var size: CGFloat = 48
    let action: () -> Void

    @Environment(\.feeqdStrings) private var strings
    @Environment(\.feeqdTheme) private var theme

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: "arrowtriangle.up.fill")
                    .font(.footnote)
                if showsCount {
                    Text("\(count)")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                }
            }
            .frame(width: size, height: size)
            .foregroundStyle(voted ? Color.white : theme.textPrimary)
            .background(
                RoundedRectangle(cornerRadius: theme.cornerRadius * 0.75, style: .continuous)
                    .fill(voted ? theme.voteActive : Color.secondary.opacity(0.2))
            )
        }
        // Borderless keeps the tap on the button instead of the row's navigation link.
        .buttonStyle(.borderless)
        .accessibilityLabel(voted ? strings(.voteVoted) : strings(.voteUpvote))
        .accessibilityValue("\(count)")
        .accessibilityAddTraits(voted ? .isSelected : [])
    }
}

/// A status as the dashboard named and coloured it. An unknown slug still renders, in grey.
struct StatusBadge: View {
    let status: RemoteStatus?
    let fallbackSlug: String

    @Environment(\.feeqdTheme) private var theme

    var body: some View {
        let color = theme.color(for: status, slug: fallbackSlug)
        Text((status?.label ?? fallbackSlug.replacingOccurrences(of: "_", with: " ")).uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.4)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .foregroundStyle(color)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color.opacity(0.16)))
    }
}

struct EntryRow: View {
    let entry: Entry
    let status: RemoteStatus?
    let voted: Bool
    let behaviour: SDKConfig.Behaviour
    let onVote: () -> Void

    @Environment(\.feeqdStrings) private var strings
    @Environment(\.feeqdTheme) private var theme

    /// Votes, then the title with where it stands beside it, then one line of what was asked.
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VoteButton(count: entry.voteCount, voted: voted, showsCount: behaviour.showVoteCount, action: onVote)
                // Nobody else sees it, so nobody can vote on it yet, the author included.
                .disabled(entry.onlyYou)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.title)
                        .font(.headline)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    StatusBadge(status: status, fallbackSlug: entry.state)
                }
                // The comments follow the text: pinned to the right they made a second column
                // under the status.
                HStack(spacing: 8) {
                    Text(entry.details ?? " ")
                        .font(.subheadline)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                    if behaviour.showCommentCount && entry.commentCount > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "bubble.left.fill")
                            Text("\(entry.commentCount)").monospacedDigit()
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(theme.textSecondary)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(entry.commentCount) \(strings(.commentsTitle))")
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }
}

struct CommentRow: View {
    let comment: Comment
    let onReply: (() -> Void)?

    @Environment(\.feeqdStrings) private var strings
    @Environment(\.feeqdTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                // The dashboard does not send a name with team replies yet: the badge alone says who it is.
                if comment.authorName != nil || !comment.isTeamMember {
                    Text(comment.authorName ?? strings(.anonymousAuthor))
                        .font(.subheadline.weight(.semibold))
                }
                if comment.isTeamMember {
                    Text(strings(.commentTeam))
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .foregroundStyle(theme.primary)
                        .background(Capsule().fill(theme.primary.opacity(0.14)))
                }
                if comment.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(theme.textSecondary)
                        .accessibilityLabel(strings(.commentPinned))
                }
                Spacer(minLength: 0)
                Text(comment.createdAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
            }
            Translatable(texts: [comment.content], spacing: 6) { shown, translateButton in
                Text(shown[0])
                    .font(.body)
                    .foregroundStyle(theme.textPrimary)
                translateButton
            }
            if comment.isPendingModeration {
                Text(strings(.commentPending))
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
            }
            if let onReply {
                Button(strings(.commentReply), action: onReply)
                    .font(.caption.weight(.medium))
                    .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Loaded, and there is nothing. Deliberately different from `ErrorStateView`: an inviting
/// empty screen after a failed load would tell someone to write into a board that isn't there.
struct EmptyStateView: View {
    let isSearch: Bool

    @Environment(\.feeqdStrings) private var strings
    @Environment(\.feeqdTheme) private var theme

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: isSearch ? "magnifyingglass" : "lightbulb")
                .font(.largeTitle)
                .foregroundStyle(theme.textSecondary)
            Text(isSearch ? strings(.searchEmpty) : strings(.emptyTitle))
                .font(.headline)
                .multilineTextAlignment(.center)
            if !isSearch {
                Text(strings(.emptyMessage))
                    .font(.subheadline)
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ErrorStateView: View {
    let error: FeeqdError
    let retry: () -> Void

    @Environment(\.feeqdStrings) private var strings
    @Environment(\.feeqdTheme) private var theme

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(theme.textSecondary)
            Text(strings(.errorTitle))
                .font(.headline)
            Text(feeqdMessage(for: error, strings: strings))
                .font(.subheadline)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
            Button(strings(.errorRetry), action: retry)
                .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PoweredByFeeqd: View {
    @Environment(\.feeqdStrings) private var strings

    var body: some View {
        Text(strings(.poweredBy))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
    }
}
