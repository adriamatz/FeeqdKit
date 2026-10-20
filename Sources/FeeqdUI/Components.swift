import FeeqdCore
import SwiftUI

/// The vote control: 44pt, labelled for VoiceOver, and its own tap target inside a row.
struct VoteButton: View {
    let count: Int
    let voted: Bool
    let showsCount: Bool
    let action: () -> Void

    @Environment(\.feeqdStrings) private var strings
    @Environment(\.feeqdTheme) private var theme

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: voted ? "arrowtriangle.up.fill" : "arrowtriangle.up")
                    .font(.footnote)
                if showsCount {
                    Text("\(count)")
                        .font(.footnote.weight(.semibold))
                        .monospacedDigit()
                }
            }
            .frame(minWidth: 44, minHeight: 44)
            .foregroundStyle(voted ? theme.voteActive : theme.textSecondary)
            .background(
                RoundedRectangle(cornerRadius: theme.cornerRadius * 0.66, style: .continuous)
                    .fill(voted ? theme.voteActive.opacity(0.14) : theme.surface)
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
        Text(status?.label ?? fallbackSlug.replacingOccurrences(of: "_", with: " ").capitalized)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

/// On the author's own request that nobody else sees yet, in place of its status.
struct OnlyYouBadge: View {
    @Environment(\.feeqdStrings) private var strings

    var body: some View {
        Label(strings(.entryOnlyYou), systemImage: "eye.slash")
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(.secondary)
            .background(Capsule().fill(Color.secondary.opacity(0.14)))
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

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VoteButton(count: entry.voteCount, voted: voted, showsCount: behaviour.showVoteCount, action: onVote)
                // Nobody else sees it, so nobody can vote on it yet, the author included.
                .disabled(entry.onlyYou)
                .opacity(entry.onlyYou ? 0.4 : 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title)
                    .font(.headline)
                    .foregroundStyle(theme.textPrimary)
                if let details = entry.details {
                    Text(details)
                        .font(.subheadline)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(2)
                }
                HStack(spacing: 8) {
                    if entry.onlyYou {
                        OnlyYouBadge()
                    } else {
                        StatusBadge(status: status, fallbackSlug: entry.state)
                    }
                    if behaviour.showCommentCount && entry.commentCount > 0 {
                        Label("\(entry.commentCount)", systemImage: "bubble.left")
                            .font(.caption)
                            .foregroundStyle(theme.textSecondary)
                            .accessibilityLabel("\(entry.commentCount) \(strings(.commentsTitle))")
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
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
            Text(comment.content)
                .font(.body)
                .foregroundStyle(theme.textPrimary)
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
