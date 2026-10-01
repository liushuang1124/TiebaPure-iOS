import Foundation

enum TiebaForumName {
    static func normalized(_ value: String) -> String {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasSuffix("吧") {
            normalized.removeLast()
            normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return normalized.lowercased()
    }
}

// Feed and thread mapping consult the blocklist from async request code, so
// the active rules are a Sendable value swapped behind a lock instead of a
// read of the main-actor BlocklistStore. Keywords and forum names must be
// stored in canonical form, user names folded via TiebaUserName.normalized;
// BlocklistSnapshot(entries:) produces that shape.
struct BlocklistSnapshot: Equatable, Sendable {
    var keywords: Set<String>
    var userIDs: Set<Int64>
    var userNames: Set<String>
    var forumIDs: Set<Int64>
    var forumNames: Set<String>

    init(
        keywords: Set<String> = [],
        userIDs: Set<Int64> = [],
        userNames: Set<String> = [],
        forumIDs: Set<Int64> = [],
        forumNames: Set<String> = []
    ) {
        self.keywords = keywords
        self.userIDs = userIDs
        self.userNames = userNames
        self.forumIDs = Set(forumIDs.filter { $0 > 0 })
        self.forumNames = Set(
            forumNames
                .map(TiebaForumName.normalized)
                .filter { $0.isEmpty == false }
        )
    }

    var isEmpty: Bool {
        keywords.isEmpty
            && userIDs.isEmpty
            && userNames.isEmpty
            && forumIDs.isEmpty
            && forumNames.isEmpty
    }

    func containsKeyword(in text: String) -> Bool {
        guard keywords.isEmpty == false, text.isEmpty == false else { return false }
        let lowercased = text.lowercased()
        return keywords.contains { lowercased.contains($0) }
    }

    func blocksUser(id: Int64, names: [String]) -> Bool {
        if id > 0, userIDs.contains(id) { return true }
        guard userNames.isEmpty == false else { return false }
        return names.contains { name in
            guard name.isEmpty == false else { return false }
            return userNames.contains(TiebaUserName.normalized(name))
        }
    }

    func blocksForum(named name: String) -> Bool {
        blocksForum(id: nil, names: [name])
    }

    func blocksForum(id: Int64?, names: [String]) -> Bool {
        if let id, id > 0, forumIDs.contains(id) {
            return true
        }
        guard forumNames.isEmpty == false else { return false }
        return names.contains { name in
            let normalized = TiebaForumName.normalized(name)
            return normalized.isEmpty == false && forumNames.contains(normalized)
        }
    }
}

enum TiebaContentFilter {
    // Reads happen off the main actor during mapping; the store publishes on
    // the main actor. The lock keeps both sides safe, and the first read
    // hydrates from persisted entries so muting applies before any UI has
    // touched BlocklistStore.
    private static let blocklistLock = NSLock()
    private static var storedBlocklist: BlocklistSnapshot?

    static func updateBlocklist(_ snapshot: BlocklistSnapshot) {
        blocklistLock.lock()
        defer { blocklistLock.unlock() }
        storedBlocklist = snapshot
    }

    static var blocklist: BlocklistSnapshot {
        blocklistLock.lock()
        defer { blocklistLock.unlock() }
        if let storedBlocklist { return storedBlocklist }
        let hydrated = BlocklistSnapshot(entries: BlocklistPersistence.loadEntries())
        storedBlocklist = hydrated
        return hydrated
    }

    /// Server-page structural filtering. This intentionally excludes the
    /// user-managed blocklist so callers can retain the original page
    /// cardinality when deciding whether another page exists.
    static func shouldMap(thread: Tieba_ThreadInfo) -> Bool {
        if thread.hasAlaInfo { return false }
        if thread.hasTwzhiboInfo { return false }
        if thread.isDeleted != 0 { return false }
        return true
    }

    static func shouldKeep(thread: Tieba_ThreadInfo) -> Bool {
        guard shouldMap(thread: thread) else { return false }
        let blocklist = Self.blocklist
        guard blocklist.isEmpty == false else { return true }
        if blocklist.blocksUser(
            id: thread.author.id > 0 ? thread.author.id : thread.authorID,
            names: [thread.author.nameShow, thread.author.name]
        ) { return false }
        let forumID = thread.forumID > 0
            ? thread.forumID
            : (thread.hasForumInfo ? thread.forumInfo.id : 0)
        let forumNames = [
            thread.forumName,
            thread.hasForumInfo ? thread.forumInfo.name : ""
        ]
        if blocklist.blocksForum(id: forumID, names: forumNames) {
            return false
        }
        if blocklist.containsKeyword(in: thread.title) { return false }
        if thread.abstract.contains(where: { blocklist.containsKeyword(in: $0.text) }) {
            return false
        }
        return true
    }

    static func shouldKeep(thread: ThreadSummary) -> Bool {
        let blocklist = Self.blocklist
        guard blocklist.isEmpty == false else { return true }
        if blocklist.blocksUser(
            id: thread.author.id,
            names: [thread.author.displayName, thread.author.name]
        ) { return false }
        if blocklist.blocksForum(
            id: thread.forumID,
            names: thread.forumName.map { [$0] } ?? []
        ) {
            return false
        }
        if blocklist.containsKeyword(in: thread.title) { return false }
        return blocklist.containsKeyword(in: thread.textPreview) == false
    }

    static func shouldKeep(searchResult: SearchResult) -> Bool {
        shouldKeep(thread: searchResult.threadSummary)
    }

    /// Applies the same local mute rules to reply/@ feeds without changing
    /// their server pagination metadata.
    static func shouldKeep(message: MessageItem) -> Bool {
        let blocklist = Self.blocklist
        guard blocklist.isEmpty == false else { return true }
        if blocklist.blocksUser(
            id: message.author.id,
            names: [message.author.displayName, message.author.name]
        ) {
            return false
        }
        if blocklist.containsKeyword(in: message.content)
            || blocklist.containsKeyword(in: message.threadTitle) {
            return false
        }
        if let forumName = message.forumName,
           blocklist.blocksForum(named: forumName) {
            return false
        }
        return true
    }

    static func shouldKeep(user: UserSummary) -> Bool {
        Self.blocklist.blocksUser(
            id: user.id,
            names: [user.displayName, user.name]
        ) == false
    }

    static func shouldKeep(forum: Forum) -> Bool {
        let blocklist = Self.blocklist
        return blocklist.blocksForum(
            id: forum.id,
            names: [forum.name, forum.displayName]
        ) == false
    }

    static func shouldMap(post: Tieba_Post) -> Bool {
        if post.hasAdvertisement { return false }
        if post.isFold != 0 { return false }
        if post.content.contains(where: shouldKeep(content:)) { return true }
        // A content-less floor with 楼中楼 still owns reachable text replies.
        // Empty and invalid-voice-only floors otherwise have nothing to show.
        return post.subPostNumber > 0
            || post.subPostList.subPostList.isEmpty == false
    }

    static func shouldKeep(post: Tieba_Post) -> Bool {
        guard shouldMap(post: post) else { return false }
        let blocklist = Self.blocklist
        if blocklist.isEmpty == false {
            if blocklist.blocksUser(
                id: post.author.id > 0 ? post.author.id : post.authorID,
                names: [post.author.nameShow, post.author.name]
            ) { return false }
            if post.content.contains(where: { blocklist.containsKeyword(in: $0.text) }) {
                return false
            }
        }
        return true
    }

    static func shouldKeep(post: Post) -> Bool {
        let blocklist = Self.blocklist
        guard blocklist.isEmpty == false else { return true }
        if blocklist.blocksUser(
            id: post.author.id,
            names: [post.author.displayName, post.author.name]
        ) { return false }
        return blocklist.containsKeyword(in: post.contentPreview) == false
    }

    /// A blocklist controls discovery and replies, but it must not remove the
    /// structural first floor after the user has explicitly opened a thread.
    static func shouldKeep(post: Post, asOpenedThreadMainPost isMainPost: Bool) -> Bool {
        isMainPost || shouldKeep(post: post)
    }

    static func shouldKeep(subpost: Tieba_SubPostList) -> Bool {
        let blocklist = Self.blocklist
        guard blocklist.isEmpty == false else { return true }
        if blocklist.blocksUser(
            id: subpost.author.id > 0 ? subpost.author.id : subpost.authorID,
            names: [subpost.author.nameShow, subpost.author.name]
        ) { return false }
        return subpost.content.contains { blocklist.containsKeyword(in: $0.text) } == false
    }

    static func shouldKeep(subpost: Subpost) -> Bool {
        let blocklist = Self.blocklist
        guard blocklist.isEmpty == false else { return true }
        if blocklist.blocksUser(
            id: subpost.author.id,
            names: [subpost.author.displayName, subpost.author.name]
        ) { return false }
        let text = subpost.blocks.compactMap(\.plainText).joined()
        return blocklist.containsKeyword(in: text) == false
    }

    static func shouldKeep(content: Tieba_PbContent) -> Bool {
        guard content.type == 10 else { return true }
        return VoiceContent(
            md5: content.voiceMd5,
            durationMilliseconds: Int(content.duringTime)
        ) != nil
    }
}
