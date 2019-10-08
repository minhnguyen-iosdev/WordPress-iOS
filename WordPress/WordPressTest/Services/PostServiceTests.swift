
import Foundation
import Nimble
@testable import WordPress

class PostServiceTests: XCTestCase {

    private var remoteMock: PostServiceRemoteMock!
    private var service: PostService!
    private var context: NSManagedObjectContext!

    private let impossibleFailureBlock: (Error?) -> Void = { _ in
        assertionFailure("This shouldn't happen.")
    }

    override func setUp() {
        super.setUp()

        context = TestContextManager().mainContext

        remoteMock = PostServiceRemoteMock()

        let remoteFactory = PostServiceRemoteFactoryMock()
        remoteFactory.remoteToReturn = remoteMock
        service = PostService(managedObjectContext: context, postServiceRemoteFactory: remoteFactory)
    }

    override func tearDown() {
        super.tearDown()

        service = nil
        remoteMock = nil
        context = nil
        ContextManager.overrideSharedInstance(nil)
    }

    func testGettingANewPostFromTheAPIWillSetTheStatusAfterSyncProperty() {
        // Arrange
        let blog = BlogBuilder(context).build()
        remoteMock.remotePostToReturnOnGetPostWithID = createRemotePost(.scheduled)

        // Act
        var post: AbstractPost?
        waitUntil(timeout: 3) { done in
            self.service.getPostWithID(123, for: blog, success: { postFromAPI in
                post = postFromAPI
                done()
            }, failure: self.impossibleFailureBlock)
        }

        // Assert
        expect(post).notTo(beNil())
        expect(post?.status).to(equal(.scheduled))
        expect(post?.statusAfterSync).to(equal(.scheduled))
        expect(post?.status).to(equal(post?.statusAfterSync))
    }

    func testSyncingPostsWillSetTheStatusAfterSyncProperty() {
        // Arrange
        let blog = BlogBuilder(context).build()
        remoteMock.remotePostsToReturnOnSyncPostsOfType =
            [createRemotePost(.scheduled), createRemotePost(.publishPrivate)]

        // Act
        var posts: [AbstractPost]?
        waitUntil(timeout: 3) { done in
            self.service.syncPosts(ofType: .any, for: blog, success: { postsFromAPI in
                posts = postsFromAPI
                done()
            }, failure: self.impossibleFailureBlock)
        }

        // Assert
        let expectedStatuses: [BasePost.Status] = [.publishPrivate, .scheduled]

        expect(posts).to(haveCount(2))
        posts?.forEach { post in
            expect(expectedStatuses).to(contain(post.status))
            expect(expectedStatuses).to(contain(post.statusAfterSync))
            expect(post.status).to(equal(post.statusAfterSync))
        }
    }

    func testUpdatingAPostWillUpdateItsStatusAfterSyncProperty() {
        // Arrange
        let post = PostBuilder(context).with(statusAfterSync: .publish).drafted().withRemote().build()
        try! context.save()

        let remotePost = createRemotePost(.draft)
        remoteMock.remotePostToReturnOnUpdatePost = remotePost

        // Act
        var postFromAPI: AbstractPost?
        waitUntil(timeout: 3) { done in
            self.service.uploadPost(post, success: { aPost in
                postFromAPI = aPost
                done()
            }, failure: self.impossibleFailureBlock)
        }

        // Assert
        expect(postFromAPI).notTo(beNil())

        // Refetch from DB to make sure we're getting the updated data.
        let postFromDB = context.object(with: postFromAPI!.objectID) as! AbstractPost
        // .draft is the status because it's what the returned RemotePost has
        expect(postFromDB.statusAfterSync).to(equal(.draft))
        expect(postFromDB.status).to(equal(.draft))
    }

    func testAutoSavingALocalDraftWillCallTheCreateEndpointInstead() {
        // Arrange
        let post = PostBuilder(context).drafted().with(remoteStatus: .local).build()
        try! context.save()

        // Act
        remoteMock.remotePostToReturnOnCreatePost = createRemotePost(.draft)
        waitUntil(timeout: 3) { done in
            self.service.autoSave(post, success: { _, _ in
                done()
            }, failure: self.impossibleFailureBlock)
        }

        // Assert
        expect(self.remoteMock.invocationsCountOfCreatePost).to(equal(1))
        expect(post.remoteStatus).to(equal(.sync))
    }

    /// Local drafts with `.published` status will be created on the server as a `.draft`.
    func testAutoSavingALocallyPublishedDraftWillCreateThePostAsADraft() {
        // Arrange
        let post = PostBuilder(context).published().with(remoteStatus: .local).build()
        try! context.save()

        // Act
        remoteMock.remotePostToReturnOnCreatePost = createRemotePost(.draft)
        waitUntil(timeout: 3) { done in
            self.service.autoSave(post, success: { _, _ in
                done()
            }, failure: self.impossibleFailureBlock)
        }

        // Assert
        expect(self.remoteMock.invocationsCountOfCreatePost).to(equal(1))
        expect(post.remoteStatus).to(equal(.sync))
    }

    func testAutoSavingAnExistingPostWillCallTheAutoSaveEndpoint() {
        // Arrange
        let post = PostBuilder(context).published().withRemote().with(remoteStatus: .sync).build()
        try! context.save()

        // Act
        remoteMock.remotePostToReturnOnAutoSave = createRemotePost(.publish)
        waitUntil(timeout: 3) { done in
            self.service.autoSave(post, success: { _, _ in
                done()
            }, failure: self.impossibleFailureBlock)
        }

        // Assert
        expect(self.remoteMock.invocationsCountOfAutoSave).to(equal(1))
        expect(post.remoteStatus).to(equal(.autoSaved))
    }

    private func createRemotePost(_ status: BasePost.Status = .draft) -> RemotePost {
        let remotePost = RemotePost(siteID: 1,
                                    status: status.rawValue,
                                    title: "Tenetur im",
                                    content: "Velit tempore rerum")!
        remotePost.type = "qui"
        return remotePost
    }
}

private class PostServiceRemoteFactoryMock: PostServiceRemoteFactory {
    var remoteToReturn: PostServiceRemote?

    override func forBlog(_ blog: Blog) -> PostServiceRemote? {
        return remoteToReturn
    }
}

private class PostServiceRemoteMock: PostServiceRemoteREST {
    var remotePostToReturnOnGetPostWithID: RemotePost?
    var remotePostsToReturnOnSyncPostsOfType = [RemotePost]()
    var remotePostToReturnOnUpdatePost: RemotePost?
    var remotePostToReturnOnCreatePost: RemotePost?
    var remotePostToReturnOnAutoSave: RemotePost?

    private(set) var invocationsCountOfCreatePost = 0
    private(set) var invocationsCountOfAutoSave = 0

    override func getPostWithID(_ postID: NSNumber!, success: ((RemotePost?) -> Void)!, failure: ((Error?) -> Void)!) {
        DispatchQueue.global().async {
            success(self.remotePostToReturnOnGetPostWithID)
        }
    }

    override func getPostsOfType(_ postType: String!, options: [AnyHashable: Any]! = [:], success: (([RemotePost]?) -> Void)!, failure: ((Error?) -> Void)!) {
        DispatchQueue.global().async {
            success(self.remotePostsToReturnOnSyncPostsOfType)
        }
    }

    override func update(_ post: RemotePost!, success: ((RemotePost?) -> Void)!, failure: ((Error?) -> Void)!) {
        DispatchQueue.global().async {
            success(self.remotePostToReturnOnUpdatePost)
        }
    }

    override func createPost(_ post: RemotePost!, success: ((RemotePost?) -> Void)!, failure: ((Error?) -> Void)!) {
        DispatchQueue.global().async {
            self.invocationsCountOfCreatePost += 1
            success(self.remotePostToReturnOnCreatePost)
        }
    }

    override func autoSave(_ post: RemotePost!, success: ((RemotePost?, String?) -> Void)!, failure: ((Error?) -> Void)!) {
        DispatchQueue.global().async {
            self.invocationsCountOfAutoSave += 1
            success(self.remotePostToReturnOnAutoSave, nil)
        }
    }
}
