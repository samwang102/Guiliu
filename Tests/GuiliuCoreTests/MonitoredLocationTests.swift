import Foundation
import Testing
@testable import GuiliuCore

@Suite("监控来源身份")
struct MonitoredLocationTests {
    @Test("微信来源 ID 由规范路径稳定生成")
    func stableIDUsesCanonicalPath() {
        let canonical = URL(fileURLWithPath: "/Users/example/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/wxid_alpha/msg/file")
        let equivalent = URL(fileURLWithPath: "/Users/example/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/wxid_alpha/msg/../msg/file/")

        let first = MonitoredLocation.stableSourceID(namespace: "wechat", directoryURL: canonical)
        let second = MonitoredLocation.stableSourceID(namespace: "wechat", directoryURL: equivalent)

        #expect(first == "wechat-6f1abc6d4cb4d99e")
        #expect(second == first)
    }

    @Test("不同微信账号目录不会共享来源 ID")
    func distinctDirectoriesHaveDistinctIDs() {
        let firstURL = URL(fileURLWithPath: "/Users/example/xwechat_files/wxid_alpha/msg/file")
        let secondURL = URL(fileURLWithPath: "/Users/example/xwechat_files/wxid_beta/msg/file")

        let first = MonitoredLocation.stableSourceID(namespace: "wechat", directoryURL: firstURL)
        let second = MonitoredLocation.stableSourceID(namespace: "wechat", directoryURL: secondURL)

        #expect(first != second)
        #expect(first.hasPrefix("wechat-"))
        #expect(second.hasPrefix("wechat-"))
    }

    @Test("用户管理目录始终移动，不因来源 App 标签改成复制")
    func userManagedSourceMovesRegardlessOfOrigin() {
        let downloads = MonitoredLocation(
            id: "downloads",
            displayName: "下载文件夹",
            url: URL(fileURLWithPath: "/Users/example/Downloads"),
            origin: .wechat
        )

        #expect(downloads.fileOwnership == .userManaged)
        #expect(downloads.routingOperation == .move)
        #expect(downloads.operationDescription.contains("不在来源目录保留副本"))
    }

    @Test("QQ 与飞书用户自选目录采用移动策略")
    func explicitAppSaveFoldersMove() {
        let qq = MonitoredLocation(
            id: "qq-custom",
            displayName: "QQ 专用保存目录",
            url: URL(fileURLWithPath: "/Users/example/QQ Files"),
            origin: .qq
        )
        let feishu = MonitoredLocation(
            id: "feishu-custom",
            displayName: "飞书专用保存目录",
            url: URL(fileURLWithPath: "/Users/example/Feishu Files"),
            origin: .feishu
        )

        #expect(qq.routingOperation == .move)
        #expect(feishu.routingOperation == .move)
    }

    @Test("只有明确 App 管理的原件采用引用策略")
    func appManagedOriginalReferences() {
        let weChatInternal = MonitoredLocation(
            id: "wechat-managed",
            displayName: "微信接收文件",
            url: URL(fileURLWithPath: "/Users/example/xwechat_files/wxid/msg/file"),
            origin: .wechat,
            fileOwnership: .appManagedOriginal,
            recursive: true
        )

        #expect(weChatInternal.routingOperation == .reference)
        #expect(weChatInternal.operationDescription.contains("创建引用"))
    }

    @Test("重叠监控按文件的最具体物理来源决定动作")
    func overlappingLocationsUseMostSpecificPhysicalOwner() {
        let downloads = MonitoredLocation(
            id: "downloads",
            displayName: "下载文件夹",
            url: URL(fileURLWithPath: "/Users/example/Downloads"),
            origin: .downloads
        )
        let managedSubtree = MonitoredLocation(
            id: "wechat-managed",
            displayName: "微信接收文件",
            url: URL(fileURLWithPath: "/Users/example/Downloads/WeChat Managed"),
            origin: .wechat,
            fileOwnership: .appManagedOriginal,
            recursive: true
        )

        let ordinaryDownload = URL(fileURLWithPath: "/Users/example/Downloads/report.pdf")
        let appOriginal = URL(fileURLWithPath: "/Users/example/Downloads/WeChat Managed/report.pdf")

        #expect(MonitoredLocation.preferred(
            for: ordinaryDownload,
            among: [downloads, managedSubtree]
        )?.routingOperation == .move)
        #expect(MonitoredLocation.preferred(
            for: appOriginal,
            among: [downloads, managedSubtree]
        )?.routingOperation == .reference)
    }

    @Test("非递归下载监控不会声称拥有子文件夹中的文件")
    func nonRecursiveSourceOwnsOnlyDirectChildren() {
        let downloads = MonitoredLocation(
            id: "downloads",
            displayName: "下载文件夹",
            url: URL(fileURLWithPath: "/Users/example/Downloads"),
            origin: .downloads
        )

        #expect(downloads.contains(fileURL: URL(fileURLWithPath: "/Users/example/Downloads/report.pdf")))
        #expect(!downloads.contains(fileURL: URL(fileURLWithPath: "/Users/example/Downloads/sub/report.pdf")))
    }
}
