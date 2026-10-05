import Baton
import CatonCore
import SwiftUI

/// The viewer's own open pull requests and where each stands: whose move it
/// is, whom it waits on, since when.
///
/// Everything this screen asks GitHub for is declared here, beside the code
/// that reads it: the query, the list's connection, a row, and the standing
/// a row (and the app model) reads. The model asks the environment for the
/// same query value, so it shares this view's handle: it keeps the list fresh
/// in the background and reads it for reminders and the keyboard, while the
/// view only renders: `storeOrNetwork` shows what the store holds and fetches
/// only what it lacks. A pull request here is the same record the inbox's row
/// for it reads, so a merge or a CI result seen by either shows in both.
struct MyPullRequestsView: View {
    @Query("""
        query MyPullRequestsQuery {
          viewer {
            login
            ...MyPullRequestList_user
          }
        }
        """, fetchPolicy: .storeOrNetwork)
    var pullRequests: MyPullRequestsQuery
    let model: AppModel

    var body: some View {
        switch pullRequests.phase {
        case .ready(let data):
            MyPullRequestList(user: data.viewer.myPullRequestList, viewer: data.viewer.login, model: model)
        case .loading:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let error):
            VStack(spacing: 8) {
                Image(systemName: "wifi.exclamationmark").font(.system(size: 22)).foregroundStyle(.tertiary)
                Text("Couldn't load your pull requests").font(.system(size: 13)).foregroundStyle(.secondary)
                Text(String(describing: error)).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(3)
                Button("Try Again") { pullRequests.retry() }.controlSize(.small)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The list: a cursor connection the fragment owns. Pages merge in the
/// store; the last row asks for the next page when it appears.
struct MyPullRequestList: View {
    @Fragment("""
        fragment MyPullRequestList_user on User
        @refetchable(queryName: "MyPullRequestListPaginationQuery")
        @argumentDefinitions(count: {type: "Int", defaultValue: 30}, cursor: {type: "String"}) {
          pullRequests(first: $count, after: $cursor, states: OPEN, orderBy: {field: UPDATED_AT, direction: DESC})
            @connection(key: "MyPullRequestList_pullRequests") {
            totalCount
            edges {
              node {
                id
                url
                repository { isArchived }
                ...MyPullRequestRow_pullRequest
                ...PullRequestStanding_pullRequest
              }
            }
          }
        }
        """)
    var user: MyPullRequestList_user
    let viewer: String
    let model: AppModel

    private func row(_ node: MyPullRequests.Node) -> some View {
        MyPullRequestRow(
            pullRequest: node.myPullRequestRow,
            standing: node.pullRequestStanding,
            followUp: model.followUp(for: node.id),
            pendingNote: model.pendingWriteNote(for: node.id),
            isSelected: model.selectedID == .pullRequest(node.id),
            onOpen: { model.openPullRequest(node.id) },
            onRemind: { model.beginReminder(node.id) },
            onNudge: { model.nudge(node.id) },
            onReady: { model.markReadyForReview(node.id) }
        )
        .id(RowID.pullRequest(node.id))
    }

    var body: some View {
        let groups = MyPullRequests.groups(user, now: .now)
        if groups.isEmpty, !user.pullRequests.hasNext {
            VStack(spacing: 6) {
                LogoImage(size: 40)
                Text("No open pull requests").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(groups, id: \.group) { group in
                            Text("\(group.group.title) · \(group.nodes.count)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.top, 6)
                                .padding(.bottom, 2)
                            ForEach(group.nodes, id: \.id) { node in row(node) }
                        }
                        if user.pullRequests.hasNext {
                            ProgressView()
                                .controlSize(.small)
                                .padding(8)
                                .task(id: user.pullRequests.pageInfo.endCursor) {
                                    try? await user.pullRequests.loadNext()
                                }
                        }
                    }
                }
                .onChange(of: model.selectedID) { _, id in
                    guard let id else { return }
                    proxy.scrollTo(id)
                }
            }
        }
    }
}

/// One pull request: what it is and where it stands. The glyph is the inbox
/// row's own fragment, spread here; the standing line is its own view with
/// its own fragment, so a review or a check result redraws that line alone.
struct MyPullRequestRow: View {
    @Fragment("""
        fragment MyPullRequestRow_pullRequest on PullRequest {
          title
          number
          repository { nameWithOwner }
          ...PullRequestIcon_pullRequest
        }
        """)
    var pullRequest: MyPullRequestRow_pullRequest
    let standing: PullRequestStanding_pullRequest
    let followUp: FollowUp?
    /// A write waiting out its undo window: "asking again…".
    let pendingNote: String?
    let isSelected: Bool
    let onOpen: () -> Void
    let onRemind: () -> Void
    let onNudge: () -> Void
    let onReady: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            PullRequestIcon(pullRequest: pullRequest.pullRequestIcon, isUnread: true)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(verbatim: "\(pullRequest.repository.nameWithOwner)#\(pullRequest.number)")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let pendingNote {
                        Text(pendingNote).foregroundStyle(Color.accentColor).lineLimit(1)
                    } else if let followUp {
                        Label("remind \(followUp.until.formatted(.relative(presentation: .named)))", systemImage: "alarm")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 11))
                Text(pullRequest.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            if isHovered {
                HStack(spacing: 2) {
                    if pullRequest.pullRequestIcon.isDraft {
                        RowButton(symbol: "paperplane", help: "Mark ready for review (⇧R)", action: onReady)
                    } else {
                        RowButton(symbol: "hand.wave", help: "Nudge: ask the reviewers again (n)", action: onNudge)
                    }
                    RowButton(symbol: "alarm", help: followUp == nil ? "Remind me if nobody answers (h)" : "Change the reminder (h)", action: onRemind)
                }
            } else {
                StandingLabel(pullRequest: standing)
            }
        }
        .padding(.trailing, 7)
        .frame(height: 46)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.3) : isHovered ? Color.primary.opacity(0.06) : .clear)
        )
        .padding(.horizontal, 5)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction(named: "Remind me", onRemind)
    }
}

/// Where a pull request stands, in a few words: "waiting on @alex · 3d".
/// The fragment is also what the app model reads to group the list and to
/// tell whether anyone answered a reminder; both read it through
/// `MyPullRequests.status`, and the reading itself is `PullRequestStanding`.
struct StandingLabel: View {
    @Fragment("""
        fragment PullRequestStanding_pullRequest on PullRequest {
          isDraft
          isInMergeQueue
          reviewDecision
          mergeable
          createdAt
          statusCheckRollup { state }
          reviewRequests(first: 10) {
            nodes {
              requestedReviewer {
                ... on Actor { login }
                ... on Team { slug organization { login } }
                ... on User { id }
                ... on Team { id }
                ... on Bot { id }
              }
            }
          }
          latestReviews(first: 10) { nodes { author { login ... on User { id } ... on Bot { id } } state submittedAt } }
          comments(last: 1) { nodes { author { login } createdAt } }
          timelineItems(itemTypes: [REVIEW_REQUESTED_EVENT], last: 1) {
            nodes { ... on ReviewRequestedEvent { createdAt } }
          }
        }
        """)
    var pullRequest: PullRequestStanding_pullRequest

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let standing = PullRequestStanding.of(MyPullRequests.status(pullRequest))
            Text(standing.summary(now: context.date))
                .font(.system(size: 11, weight: standing.group == .yourMove ? .semibold : .regular))
                .foregroundStyle(standing.group == .yourMove ? Color.orange : Color.secondary)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

/// Reading the list's fragments into plain values, shared by the view and the
/// app model so both group the list the same way.
@MainActor
enum MyPullRequests {
    typealias Node = MyPullRequestList_user.PullRequests.Edges.Node

    struct Group {
        let group: PullRequestStanding.Group
        let nodes: [Node]
    }

    /// Open pull requests outside archived repositories, grouped by whose
    /// move it is; within a group, most recently updated first, as GitHub
    /// returns them.
    static func groups(_ user: MyPullRequestList_user, now: Date) -> [Group] {
        let nodes = user.pullRequests.nodes.filter { !$0.repository.isArchived }
        let byGroup = Dictionary(grouping: nodes) { PullRequestStanding.of(status($0.pullRequestStanding)).group }
        return PullRequestStanding.Group.allCases.compactMap { group in
            byGroup[group].map { Group(group: group, nodes: $0) }
        }
    }

    /// The standing fragment as plain data.
    static func status(_ fragment: PullRequestStanding_pullRequest) -> PullRequestStatus {
        let date = { (text: String?) in text.flatMap { try? Date($0, strategy: .iso8601) } }
        let requests = fragment.reviewRequests?.nodes.map { Array($0) } ?? []
        let reviewers = requests.compactMap { node -> PullRequestStatus.Reviewer? in
            guard let reviewer = node.requestedReviewer else { return nil }
            if let team = reviewer.asTeam { return .init(name: "\(team.organization.login)/\(team.slug)", isTeam: true, id: team.id) }
            // Each condition reads what it selects: the login through Actor,
            // the id through the concrete type a request names it by.
            guard let login = reviewer.asActor?.login else { return nil }
            if let bot = reviewer.asBot { return .init(name: login, isBot: true, id: bot.id) }
            return .init(name: login, id: reviewer.asUser?.id)
        }
        let latest = fragment.latestReviews?.nodes.map { Array($0) } ?? []
        let reviews = latest.compactMap { node -> PullRequestStatus.Review? in
            guard let login = node.author?.login, let state = SubjectFacts.ReviewState(graphQL: node.state) else { return nil }
            let author = node.author
            return PullRequestStatus.Review(login: login, state: state, at: date(node.submittedAt), userID: author?.asUser?.id, botID: author?.asBot?.id)
        }
        let comment = fragment.comments.nodes?.last.flatMap { node -> PullRequestStatus.Comment? in
            guard let login = node.author?.login, let at = date(node.createdAt) else { return nil }
            return PullRequestStatus.Comment(login: login, at: at)
        }
        let requestedAt = fragment.timelineItems.nodes?.last.flatMap { $0.asReviewRequestedEvent?.createdAt }.flatMap { date($0) }
        return PullRequestStatus(
            isDraft: fragment.isDraft,
            isInMergeQueue: fragment.isInMergeQueue,
            reviewDecision: fragment.reviewDecision.flatMap(SubjectFacts.ReviewDecision.init(graphQL:)),
            mergeable: PullRequestStatus.Mergeable(rawValue: fragment.mergeable.lowercased()) ?? .unknown,
            checks: fragment.statusCheckRollup.flatMap { SubjectFacts.Checks(graphQL: $0.state) },
            pendingReviewers: reviewers,
            latestReviews: reviews,
            requestedAt: requestedAt,
            createdAt: date(fragment.createdAt) ?? .now,
            lastComment: comment
        )
    }
}
