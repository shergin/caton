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
        query MyPullRequestsQuery @cacheExpiration(seconds: 300) {
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
            VStack(spacing: 0) {
                RefreshNotice(fetch: pullRequests.fetch) { pullRequests.retry() }
                MyPullRequestList(user: data.viewer.myPullRequestList, viewer: data.viewer.login, model: model)
            }
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

/// A failed refresh is separate from the phase: cached rows stay usable.
struct RefreshNotice: View {
    let fetch: Fetch
    let retry: () -> Void

    var body: some View {
        if let failure = fetch.failure {
            HStack {
                Label("Couldn't refresh. Showing saved data.", systemImage: "wifi.exclamationmark")
                Spacer()
                Button("Retry", action: retry).controlSize(.small)
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(8)
            .help(failure.localizedDescription)
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
            isSelected: model.panel.selectedID == .pullRequest(node.id),
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
                .onChange(of: model.panel.selectedID) { _, id in
                    guard let id else { return }
                    proxy.scrollTo(id)
                }
            }
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
        let requests = fragment.reviewRequests?.nodes ?? .empty
        let reviewers = requests.compactMap { node -> PullRequestStatus.Reviewer? in
            guard let reviewer = node.requestedReviewer else { return nil }
            if let team = reviewer.asTeam { return .init(name: "\(team.organization.login)/\(team.slug)", isTeam: true, id: team.id) }
            // Each condition reads what it selects: the login through Actor,
            // the id through the concrete type a request names it by.
            guard let login = reviewer.asActor?.login else { return nil }
            if let bot = reviewer.asBot { return .init(name: login, isBot: true, id: bot.id) }
            return .init(name: login, id: reviewer.asUser?.id)
        }
        let latest = fragment.latestReviews?.nodes ?? .empty
        let reviews = latest.compactMap { node -> PullRequestStatus.Review? in
            guard let login = node.author?.login, let state = SubjectFacts.ReviewState(graphQL: node.state) else { return nil }
            let author = node.author
            return PullRequestStatus.Review(login: login, state: state, at: node.submittedAt, userID: author?.asUser?.id, botID: author?.asBot?.id)
        }
        let comment = fragment.comments.nodes?.last.flatMap { node -> PullRequestStatus.Comment? in
            guard let login = node.author?.login, let at = node.createdAt else { return nil }
            return PullRequestStatus.Comment(login: login, at: at)
        }
        let requestedAt = fragment.catonNudgedAt ?? fragment.timelineItems.nodes?.last?.asReviewRequestedEvent?.createdAt
        let mergeable: PullRequestStatus.Mergeable = switch fragment.mergeable {
        case .MERGEABLE: .mergeable
        case .CONFLICTING: .conflicting
        default: .unknown
        }
        return PullRequestStatus(
            isDraft: fragment.isDraft,
            isInMergeQueue: fragment.isInMergeQueue,
            reviewDecision: fragment.reviewDecision.flatMap(SubjectFacts.ReviewDecision.init(graphQL:)),
            mergeable: mergeable,
            checks: fragment.statusCheckRollup.flatMap { SubjectFacts.Checks(graphQL: $0.state) },
            pendingReviewers: reviewers,
            latestReviews: reviews,
            requestedAt: requestedAt,
            createdAt: fragment.createdAt ?? .now,
            lastComment: comment
        )
    }
}
