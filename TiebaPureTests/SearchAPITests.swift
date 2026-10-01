import SwiftProtobuf
import XCTest
@testable import TiebaPure

final class SearchAPITests: XCTestCase {
    override func tearDown() {
        SearchMockURLProtocol.handler = nil
        super.tearDown()
    }

    func testGlobalSearchMapsReplyResultAndMedia() async throws {
        let api = makeAPI { request in
            let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

            XCTAssertEqual(components.path, "/mo/q/search/thread")
            XCTAssertEqual(query["word"], "iPhone 视频")
            XCTAssertEqual(query["pn"], "1")
            XCTAssertEqual(query["st"], "5")
            XCTAssertEqual(query["tt"], "2")
            XCTAssertEqual(query["ct"], "1")
            XCTAssertEqual(query["cv"], "99.9.101")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "tieba/12.52.1.0 skin/default")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Referer"),
                "https://tieba.baidu.com/mo/q/hybrid/search?keyword=iPhone%20%E8%A7%86%E9%A2%91"
            )

            return Self.searchResponseJSON
        }

        let page = try await api.searchThreads(keyword: "iPhone 视频", page: 1)

        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.currentPage, 1)
        XCTAssertEqual(page.results.count, 1)

        let result = try XCTUnwrap(page.results.first)
        XCTAssertEqual(result.threadID, 123)
        XCTAssertEqual(result.postID, 456)
        XCTAssertEqual(result.forumID, 789)
        XCTAssertEqual(result.forumName, "iPhone")
        XCTAssertEqual(result.title, "主题标题")
        XCTAssertEqual(result.content, "命中回复")
        XCTAssertEqual(result.author.displayName, "作者")
        XCTAssertTrue(result.isReplyMatch)
        XCTAssertEqual(result.blocks.count, 2)

        guard case let .image(image) = result.blocks[0] else {
            return XCTFail("expected image block")
        }
        XCTAssertEqual(image.thumbnailURL?.absoluteString, "https://tiebapic.baidu.com/forum/pic/item/a.jpg")
        XCTAssertEqual(image.originalURL?.absoluteString, "https://tiebapic.baidu.com/forum/pic/item/a_original.jpg")

        guard case let .video(video) = result.blocks[1] else {
            return XCTFail("expected video block")
        }
        XCTAssertEqual(video.videoURL?.absoluteString, "https://video.example/a.mp4")
        XCTAssertEqual(video.coverURL?.absoluteString, "https://tiebapic.baidu.com/forum/pic/item/v.jpg")
        XCTAssertEqual(video.width, 1280)
        XCTAssertEqual(video.height, 720)
    }

    func testForumSearchUsesOriginalForumParameters() async throws {
        let api = makeAPI { request in
            let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

            XCTAssertEqual(query["word"], "显卡")
            XCTAssertEqual(query["pn"], "3")
            XCTAssertEqual(query["st"], "2")
            XCTAssertEqual(query["tt"], "1")
            XCTAssertEqual(query["rn"], "30")
            XCTAssertEqual(query["fname"], "显卡")
            XCTAssertEqual(query["ct"], "2")
            XCTAssertEqual(query["cv"], "12.52.1.0")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Referer"),
                "https://tieba.baidu.com/mo/q/hybrid-usergrow-search/searchGlobal?entryPage=frs&forumName=%E6%98%BE%E5%8D%A1"
            )

            return #"{"no":0,"error":"success","data":{"has_more":0,"current_page":3,"post_list":[]}}"#.data(using: .utf8)!
        }

        let page = try await api.searchThreads(
            keyword: "显卡",
            page: 3,
            sortType: 2,
            filterType: 1,
            forumName: "显卡"
        )

        XCTAssertFalse(page.hasMore)
        XCTAssertEqual(page.currentPage, 3)
        XCTAssertTrue(page.results.isEmpty)
    }

    func testLoggedInForumThreadsFallsBackToFormWhenProtobufIsInvalid() async throws {
        final class RequestCounter {
            var count = 0
        }
        let counter = RequestCounter()
        let api = makeAPI { request in
            counter.count += 1
            let url = try XCTUnwrap(request.url)

            if counter.count == 1 {
                XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "cmd" }?.value, "301001")
                // CFNetwork drops non-ASCII header values, so the forum name
                // must travel only in the protobuf body.
                XCTAssertNil(request.value(forHTTPHeaderField: "forum_name"))
                return Data([0x0A])
            }

            XCTAssertEqual(url.host, "c.tieba.baidu.com")
            XCTAssertEqual(url.path, "/c/f/frs/page")
            return Self.forumPageResponseJSON
        }

        let threads = try await api.forumThreads(account: .preview, forumName: "显卡", page: 1)

        XCTAssertEqual(counter.count, 2)
        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(threads.first?.title, "显卡主题")
        XCTAssertEqual(threads.first?.blocks, [.text("正文"), .emoticon(code: "滑稽")])
    }

    func testForumCategoryProtobufRequestEncodesFirstPageAndPaginationFields() async throws {
        let cases: [(category: ForumThreadCategory, expectedSortType: Int32, isFeatured: Bool)] = [
            (.replyTime, 0, false),
            (.publishTime, 1, false),
            (.featured, -1, true)
        ]

        for testCase in cases {
            for (page, expectedLoadType) in [(1, Int32(1)), (2, Int32(2))] {
                let api = makeAPI { request in
                    let url = try XCTUnwrap(request.url)
                    XCTAssertEqual(url.path, "/c/f/frs/page")
                    XCTAssertEqual(
                        URLComponents(url: url, resolvingAgainstBaseURL: false)?
                            .queryItems?
                            .first { $0.name == "cmd" }?
                            .value,
                        "301001"
                    )

                    let protobuf = try Self.forumProtobufRequest(from: request)
                    XCTAssertTrue(protobuf.hasData)
                    XCTAssertEqual(protobuf.data.kw, "显卡")
                    XCTAssertEqual(protobuf.data.pn, Int32(page))
                    XCTAssertEqual(protobuf.data.loadType, expectedLoadType)
                    XCTAssertTrue(protobuf.data.hasSortType)
                    XCTAssertEqual(protobuf.data.sortType, testCase.expectedSortType)
                    XCTAssertEqual(protobuf.data.hasIsGood, testCase.isFeatured)
                    XCTAssertEqual(protobuf.data.isGood, testCase.isFeatured ? 1 : 0)
                    XCTAssertEqual(protobuf.data.hasCid, testCase.isFeatured)
                    XCTAssertEqual(protobuf.data.cid, 0)

                    return try Self.emptyForumProtobufResponse()
                }

                let threads = try await api.forumThreads(
                    account: .preview,
                    forumName: "显卡",
                    page: page,
                    category: testCase.category
                )
                XCTAssertTrue(threads.isEmpty)
            }
        }
    }

    func testAnonymousForumCategoryFormRequestEncodesFields() async throws {
        let cases: [(category: ForumThreadCategory, expectedSortType: String, isFeatured: Bool)] = [
            (.replyTime, "0", false),
            (.publishTime, "1", false),
            (.featured, "-1", true)
        ]

        for testCase in cases {
            let api = makeAPI { request in
                let url = try XCTUnwrap(request.url)
                XCTAssertEqual(url.host, "c.tieba.baidu.com")
                XCTAssertEqual(url.path, "/c/f/frs/page")

                let fields = try Self.formFields(from: request)
                XCTAssertEqual(fields["kw"], "显卡")
                XCTAssertEqual(fields["pn"], "1")
                XCTAssertEqual(fields["sort_type"], testCase.expectedSortType)
                XCTAssertEqual(fields["is_good"], testCase.isFeatured ? "1" : nil)
                XCTAssertEqual(fields["cid"], testCase.isFeatured ? "0" : nil)
                XCTAssertNotNil(fields["sign"])

                return Self.emptyForumPageResponseJSON
            }

            let threads = try await api.forumThreads(
                account: nil,
                forumName: "显卡",
                page: 1,
                category: testCase.category
            )
            XCTAssertTrue(threads.isEmpty)
        }
    }

    func testAnonymousForumThreadsMapsVoiceInfoFromObjectAndArray() async throws {
        let api = makeAPI { _ in
            """
            {
              "error_code": 0,
              "error_msg": "",
              "thread_list": [
                {
                  "id": 901,
                  "title": "对象语音帖",
                  "author_id": 42,
                  "is_voice_thread": 1,
                  "voice_info": {
                    "voice_md5": "ABCDEF0123456789ABCDEF0123456789",
                    "during_time": 3456
                  }
                },
                {
                  "id": "902",
                  "title": "数组语音帖",
                  "author_id": "42",
                  "is_voice_thread": "1",
                  "voice_info": [
                    {
                      "voice_md5": 11111111111111111111111111111111,
                      "during_time": "7890"
                    }
                  ]
                }
              ],
              "user_list": [
                {
                  "id": 42,
                  "name": "raw",
                  "name_show": "作者",
                  "portrait": "tb.1.demo"
                }
              ]
            }
            """.data(using: .utf8)!
        }

        let threads = try await api.forumThreads(
            account: nil,
            forumName: "语音测试",
            page: 1
        )

        XCTAssertEqual(threads.map(\.id), [901, 902])
        XCTAssertEqual(threads[0].blocks, [
            .voice(try XCTUnwrap(VoiceContent(
                md5: "abcdef0123456789abcdef0123456789",
                durationMilliseconds: 3_456
            )))
        ])
        XCTAssertEqual(threads[1].blocks, [
            .voice(try XCTUnwrap(VoiceContent(
                md5: "11111111111111111111111111111111",
                durationMilliseconds: 7_890
            )))
        ])
    }

    func testAnonymousForumThreadsKeepsVoiceThreadWithoutValidVoiceInfo() async throws {
        let api = makeAPI { _ in
            """
            {
              "error_code": "0",
              "error_msg": "",
              "thread_list": [
                {
                  "id": "903",
                  "title": "缺少语音信息",
                  "author_id": "42",
                  "abstract": "摘要",
                  "is_voice_thread": "1"
                },
                {
                  "id": "904",
                  "title": "无效语音信息",
                  "author_id": "42",
                  "is_voice_thread": "1",
                  "voice_info": {
                    "voice_md5": "invalid",
                    "during_time": 1000
                  }
                },
                {
                  "id": "905",
                  "title": "广告语音帖",
                  "is_voice_thread": "1",
                  "is_ad": "1"
                },
                {
                  "id": "906",
                  "title": "直播语音帖",
                  "is_voice_thread": "1",
                  "ala_info": {}
                },
                {
                  "id": "907",
                  "title": "删除语音帖",
                  "is_voice_thread": "1",
                  "is_deleted": "1"
                }
              ],
              "user_list": []
            }
            """.data(using: .utf8)!
        }

        let threads = try await api.forumThreads(
            account: nil,
            forumName: "语音测试",
            page: 1
        )

        XCTAssertEqual(threads.map(\.id), [903, 904])
        XCTAssertEqual(threads[0].blocks, [.text("摘要"), .text("[语音]")])
        XCTAssertEqual(threads[1].blocks, [.text("[语音]")])
    }

    func testForumCategoryFallbackPreservesFormFieldsAfterProtobufDecodeFailure() async throws {
        let cases: [(category: ForumThreadCategory, expectedSortType: String, isFeatured: Bool)] = [
            (.replyTime, "0", false),
            (.publishTime, "1", false),
            (.featured, "-1", true)
        ]

        for testCase in cases {
            final class RequestCounter {
                var count = 0
            }
            let counter = RequestCounter()
            let api = makeAPI { request in
                counter.count += 1
                if counter.count == 1 {
                    _ = try Self.forumProtobufRequest(from: request)
                    return Data([0x0A])
                }

                let fields = try Self.formFields(from: request)
                XCTAssertEqual(fields["sort_type"], testCase.expectedSortType)
                XCTAssertEqual(fields["is_good"], testCase.isFeatured ? "1" : nil)
                XCTAssertEqual(fields["cid"], testCase.isFeatured ? "0" : nil)
                return Self.emptyForumPageResponseJSON
            }

            let threads = try await api.forumThreads(
                account: .preview,
                forumName: "显卡",
                page: 1,
                category: testCase.category
            )
            XCTAssertEqual(counter.count, 2)
            XCTAssertTrue(threads.isEmpty)
        }
    }

    func testSearchQueryPercentEncodesPlusSpaceAmpersandAndCJK() async throws {
        let api = makeAPI { request in
            let url = try XCTUnwrap(request.url)
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let rawQuery = try XCTUnwrap(components.percentEncodedQuery)
            XCTAssertTrue(rawQuery.contains("word=C%2B%2B%20%E6%B5%8B%E8%AF%95%26x"), rawQuery)

            let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(query["word"], "C++ 测试&x")

            return #"{"no":0,"error":"success","data":{"has_more":0,"current_page":1,"post_list":[]}}"#.data(using: .utf8)!
        }

        _ = try await api.searchThreads(keyword: "C++ 测试&x", page: 1)
    }

    func testLoggedInForumThreadsRejectEmptyProtobufBody() async throws {
        let api = makeAPI { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "cmd" }?.value, "301001")
            return Data()
        }

        do {
            _ = try await api.forumThreads(account: .preview, forumName: "显卡", page: 1)
            XCTFail("Expected empty protobuf response rejection")
        } catch {
            XCTAssertEqual(error as? TiebaAPIError, .emptyResponse)
        }
    }

    func testForumFormMapsExpiredSessionBusinessCode() async throws {
        let api = makeAPI { _ in
            #"{"error_code":"110001","error_msg":"登录失效","thread_list":[],"user_list":[]}"#.data(using: .utf8)!
        }

        do {
            _ = try await api.forumThreads(account: nil, forumName: "显卡", page: 1)
            XCTFail("Expected expired session business error")
        } catch {
            XCTAssertEqual(
                error as? TiebaAPIError,
                .sessionExpired(code: 110001, message: "登录失效")
            )
        }
    }

    func testSearchMapsExpiredSessionBusinessCode() async throws {
        let api = makeAPI { _ in
            #"{"no":110001,"error":"登录失效","data":{}}"#.data(using: .utf8)!
        }

        do {
            _ = try await api.searchThreads(keyword: "测试", page: 1)
            XCTFail("Expected expired session business error")
        } catch {
            XCTAssertEqual(
                error as? TiebaAPIError,
                .sessionExpired(code: 110001, message: "登录失效")
            )
        }
    }

    func testResolveUserPrefersExactObjectOverDifferentFuzzyIdentityWithSameName() async throws {
        let api = makeAPI { request in
            let components = try XCTUnwrap(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            )
            let query = Dictionary(
                uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
            )

            XCTAssertEqual(components.path, "/mo/q/search/user")
            XCTAssertEqual(query["word"], "被回复用户")
            XCTAssertEqual(query["_client_version"], "8.0.8.0")
            XCTAssertEqual(query["cuid_gid"], "")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "bdtb for Android 8.0.8.0")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Referer"),
                "https://tieba.baidu.com/mo/q/hybrid/search?keyword=%E8%A2%AB%E5%9B%9E%E5%A4%8D%E7%94%A8%E6%88%B7"
            )

            return """
            {
              "no": "0",
              "error": "",
              "data": {
                "exactMatch": {
                  "id": "42",
                  "name": "reply_target_raw",
                  "show_nickname": "被回复用户",
                  "portrait": "tb.1.reply"
                },
                "fuzzyMatch": {
                  "different_identity": {
                    "id": 99,
                    "name": "different_raw",
                    "user_nickname": "被回复用户",
                    "portrait": "tb.1.other"
                  }
                }
              }
            }
            """.data(using: .utf8)!
        }

        let user = try await api.resolveUser(named: " @被回复用户 ")

        XCTAssertEqual(user.id, 42)
        XCTAssertEqual(user.name, "reply_target_raw")
        XCTAssertEqual(user.displayNameResolved, "被回复用户")
        XCTAssertEqual(user.portrait, "tb.1.reply")
    }

    func testResolveUserAcceptsFuzzyObjectWhenExactMatchIsEmpty() async throws {
        let api = makeAPI { _ in
            """
            {
              "no": 0,
              "error": "",
              "data": {
                "exactMatch": [],
                "fuzzyMatch": {
                  "only_candidate": {
                    "id": "9",
                    "name": "target_raw",
                    "user_nickname": "目标用户"
                  }
                }
              }
            }
            """.data(using: .utf8)!
        }

        let user = try await api.resolveUser(named: "目标用户")

        XCTAssertEqual(user.id, 9)
        XCTAssertEqual(user.displayNameResolved, "目标用户")
    }

    func testResolveUserAcceptsEmptyExactArrayAndFuzzyArrayWithNormalizedExactMatch() async throws {
        let api = makeAPI { _ in
            """
            {
              "no": 0,
              "error": "",
              "data": {
                "exactMatch": [],
                "fuzzyMatch": [
                  {
                    "id": "7",
                    "name": "alice_raw",
                    "show_nickname": "Ａｌｉｃｅ"
                  },
                  {
                    "id": "8",
                    "name": "alice_other",
                    "show_nickname": "Alice2"
                  }
                ]
              }
            }
            """.data(using: .utf8)!
        }

        let user = try await api.resolveUser(named: "alice")

        XCTAssertEqual(user.id, 7)
        XCTAssertEqual(user.displayNameResolved, "Ａｌｉｃｅ")
    }

    func testResolveUserRejectsAmbiguousNormalizedExactMatches() async throws {
        let api = makeAPI { _ in
            """
            {
              "no": 0,
              "error": "",
              "data": {
                "exactMatch": [],
                "fuzzyMatch": [
                  {"id": "7", "name": "first", "show_nickname": "同名用户"},
                  {"id": "8", "name": "second", "show_nickname": "同名用户"}
                ]
              }
            }
            """.data(using: .utf8)!
        }

        do {
            _ = try await api.resolveUser(named: "同名用户")
            XCTFail("Expected ambiguous exact-name result to be rejected")
        } catch {
            XCTAssertEqual(
                error as? UserNameResolutionError,
                .ambiguousExactMatches("同名用户")
            )
        }
    }

    func testResolveUserRejectsFuzzyNonExactName() async throws {
        let api = makeAPI { _ in
            """
            {
              "no": 0,
              "error": "",
              "data": {
                "exactMatch": [],
                "fuzzyMatch": {
                  "candidate": {
                    "id": "7",
                    "name": "different_raw",
                    "show_nickname": "被回复用户2"
                  }
                }
              }
            }
            """.data(using: .utf8)!
        }

        do {
            _ = try await api.resolveUser(named: "被回复用户")
            XCTFail("Expected fuzzy-only non-exact result to be rejected")
        } catch {
            XCTAssertEqual(
                error as? UserNameResolutionError,
                .noExactMatch("被回复用户")
            )
        }
    }

    private func makeAPI(handler: @escaping (URLRequest) throws -> Data) -> TiebaAPI {
        SearchMockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SearchMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return TiebaAPI(client: TiebaHTTPClient(session: session))
    }

    private static func forumProtobufRequest(
        from request: URLRequest
    ) throws -> Tieba_FrsPage_FrsPageRequest {
        let body = try requestBody(from: request)
        let payloadHeader = try XCTUnwrap(
            "Content-Disposition: form-data; name=\"data\"; filename=\"file\"\r\n"
                .appending("Content-Type: application/octet-stream\r\n\r\n")
                .data(using: .utf8)
        )
        let payloadStart = try XCTUnwrap(body.range(of: payloadHeader)).upperBound
        let payloadTrailer = try XCTUnwrap(
            "\r\n--\(TiebaRequestBuilder.boundary)--\r\n".data(using: .utf8)
        )
        let payloadEnd = try XCTUnwrap(
            body.range(
                of: payloadTrailer,
                options: [],
                in: payloadStart..<body.endIndex
            )
        ).lowerBound
        return try Tieba_FrsPage_FrsPageRequest(
            serializedBytes: body[payloadStart..<payloadEnd]
        )
    }

    private static func formFields(from request: URLRequest) throws -> [String: String] {
        let body = try requestBody(from: request)
        let bodyText = try XCTUnwrap(String(data: body, encoding: .utf8))
        var components = URLComponents()
        components.percentEncodedQuery = bodyText
        return Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map {
                ($0.name, $0.value ?? "")
            }
        )
    }

    private static func requestBody(from request: URLRequest) throws -> Data {
        if let body = request.httpBody {
            return body
        }

        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }

        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 {
                throw try XCTUnwrap(stream.streamError)
            }
            if count == 0 {
                break
            }
            body.append(contentsOf: buffer.prefix(count))
        }
        return body
    }

    private static func emptyForumProtobufResponse() throws -> Data {
        var response = Tieba_FrsPage_FrsPageResponse()
        response.data = Tieba_FrsPage_FrsPageResponseData()
        return try response.serializedData()
    }

    private static let searchResponseJSON = """
    {
      "no": 0,
      "error": "success",
      "data": {
        "has_more": 1,
        "current_page": 1,
        "post_list": [
          {
            "tid": "123",
            "pid": "456",
            "title": "主题标题",
            "content": "",
            "time": "1710000000",
            "post_num": "12",
            "like_num": "3",
            "share_num": "1",
            "forum_id": "789",
            "forum_name": "iPhone",
            "user": {
              "user_id": "42",
              "user_name": "raw",
              "show_nickname": "作者",
              "portrait": "tb.1.demo"
            },
            "post_info": {
              "title": "回复标题",
              "content": "命中回复"
            },
            "media": [
              {
                "type": "pic",
                "width": "800",
                "height": "600",
                "big_pic": "https://tiebapic.baidu.com/forum/pic/item/a.jpg",
                "src": "//tiebapic.baidu.com/forum/pic/item/a_original.jpg"
              },
              {
                "type": "flash",
                "width": "1280",
                "height": "720",
                "vsrc": "https://video.example/a.mp4",
                "vpic": "https://tiebapic.baidu.com/forum/pic/item/v.jpg"
              }
            ]
          }
        ]
      }
    }
    """.data(using: .utf8)!

    private static let forumPageResponseJSON = """
    {
      "error_code": "0",
      "error_msg": "",
      "thread_list": [
        {
          "id": "321",
          "title": "显卡主题",
          "reply_num": "4",
          "view_num": "20",
          "agree_num": "7",
          "author_id": "42",
          "abstract": "正文#(滑稽)"
        }
      ],
      "user_list": [
        {
          "id": "42",
          "name": "raw",
          "name_show": "作者",
          "portrait": "tb.1.demo"
        }
      ]
    }
    """.data(using: .utf8)!

    private static let emptyForumPageResponseJSON = """
    {
      "error_code": "0",
      "error_msg": "",
      "thread_list": [],
      "user_list": []
    }
    """.data(using: .utf8)!
}

private final class SearchMockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> Data)?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            let data = try XCTUnwrap(Self.handler)(request)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
