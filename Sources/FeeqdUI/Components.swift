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

/// Where a request stands, as a shape before a word: dashed while it waits, a ring once looked
/// at, a dot inside when planned, half full in progress, filled when closed. The same marks the
/// dashboard draws, in the colour the dashboard gave the status.
struct StatusMark: View {
    let status: RemoteStatus?
    let fallbackSlug: String
    var size: CGFloat = 13

    @Environment(\.feeqdTheme) private var theme

    private enum Mark { case waiting, reviewed, planned, progress, done, declined }

    private var shape: Mark {
        let slug = status?.slug ?? fallbackSlug
        switch slug {
        case "pending", "reported": return .waiting
        case "in_review": return .reviewed
        case "planned", "confirmed": return .planned
        case "in_progress", "known_issue": return .progress
        case "completed", "fixed", "implemented": return .done
        case "declined", "cannot_reproduce", "rejected": return .declined
        default:
            switch status?.category {
            case .progress: return .progress
            case .closed: return .done
            default: return .reviewed
            }
        }
    }

    var body: some View {
        let color = theme.color(for: status, slug: fallbackSlug)
        let line = size * 0.12
        ZStack {
            switch shape {
            case .done, .declined:
                Circle().fill(color)
                Image(systemName: shape == .done ? "checkmark" : "xmark")
                    .font(.system(size: size * 0.55, weight: .heavy))
                    .foregroundStyle(.white)
            case .waiting:
                Circle().strokeBorder(color, style: StrokeStyle(lineWidth: line, dash: [size * 0.15, size * 0.15]))
            case .reviewed:
                Circle().strokeBorder(color, lineWidth: line)
            case .planned:
                Circle().strokeBorder(color, lineWidth: line)
                Circle().fill(color).frame(width: size * 0.3, height: size * 0.3)
            case .progress:
                Circle().strokeBorder(color, lineWidth: line)
                HalfCircle().fill(color).padding(size * 0.22)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The right half of a circle, for the in-progress mark.
private struct HalfCircle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addArc(center: center, radius: rect.width / 2, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
        path.closeSubpath()
        return path
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

    /// Votes, then the title, and under it where it stands and how much it was talked about.
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VoteButton(count: entry.voteCount, voted: voted, showsCount: behaviour.showVoteCount, size: 44, action: onVote)
                // Nobody else sees it, so nobody can vote on it yet, the author included.
                .disabled(entry.onlyYou)
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.title)
                    .font(.headline)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(2)
                HStack(spacing: 10) {
                    HStack(spacing: 5) {
                        StatusMark(status: status, fallbackSlug: entry.state)
                        Text(status?.label ?? entry.state.replacingOccurrences(of: "_", with: " ").capitalized)
                    }
                    if behaviour.showCommentCount && entry.commentCount > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "bubble.left")
                            Text("\(entry.commentCount)").monospacedDigit()
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(entry.commentCount) \(strings(.commentsTitle))")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
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
            Translatable(texts: [comment.content], spacing: 6) { shown, translateButton in
                Text(shown[0])
                    .font(.body)
                    .foregroundStyle(theme.textPrimary)
                translateButton
            }
            if let appStoreID = comment.reviewAppStoreID {
                ReviewCard(appStoreID: appStoreID)
            }
            if comment.isPendingSend {
                PendingSendNote(text: strings(.sendPending))
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
            } else if comment.isPendingModeration {
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

/// What the team sends under a message or a reply when it asks for a review: the app's page on the App
/// Store, opened at its review form. A link, not a rating prompt: Apple keeps those to its own
/// API, so the stars are drawn only to say what the button is for.
struct ReviewCard: View {
    let appStoreID: String

    @Environment(\.feeqdStrings) private var strings
    @Environment(\.feeqdTheme) private var theme
    @Environment(\.openURL) private var openURL

    private var reviewURL: URL? { URL(string: "https://apps.apple.com/app/id\(appStoreID)?action=write-review") }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(strings(.reviewTitle))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.textPrimary)
            HStack(spacing: 4) {
                ForEach(0..<5, id: \.self) { _ in
                    Image(systemName: "star.fill")
                }
            }
            .font(.footnote)
            .foregroundStyle(Color.orange)
            .accessibilityHidden(true)
            Button {
                if let reviewURL { openURL(reviewURL) }
            } label: {
                Text(strings(.reviewButton))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Capsule().fill(theme.primary))
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
                .fill(theme.textSecondary.opacity(0.14))
        )
    }
}

/// "Not sent yet" under something the user wrote that is waiting to go out.
struct PendingSendNote: View {
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "clock")
            Text(text)
        }
    }
}
