import Foundation
import Testing
@testable import GuiliuCore

@Suite("智能标签")
struct SmartTaggerTests {
    private let tagger = SmartTagger()

    @Test("从文件名与来源生成项目、机构、合同和重要资料标签")
    func extractsSemanticAndSourceTags() {
        let url = URL(fileURLWithPath: "/tmp/项目：示例项目_示例科技有限公司_合同_最终版.pdf")

        let tags = tagger.tags(
            for: url,
            category: .documentsReports,
            origin: .wechat
        )

        #expect(tags.contains(SmartTag(kind: .project, value: "示例项目")))
        #expect(tags.contains(SmartTag(kind: .organization, value: "示例科技有限公司")))
        #expect(tags.contains(SmartTag(kind: .documentType, value: "合同")))
        #expect(tags.contains(SmartTag(kind: .importance, value: "重要资料")))
        #expect(tags.contains(SmartTag(kind: .source, value: "微信")))
    }

    @Test("同义关键词不会生成重复标签且总数受限")
    func deduplicatesAndBoundsTags() {
        let url = URL(
            fileURLWithPath: "/tmp/项目：示例项目_示例科技有限公司_合同_协议_NDA_会议_周报_手册_已签_最终版.pdf"
        )

        let tags = tagger.tags(
            for: url,
            category: .documentsReports,
            origin: .feishu,
            contentText: "contract agreement NDA 合同 协议"
        )

        #expect(tags.count == 8)
        #expect(Set(tags.map(\.id)).count == tags.count)
        #expect(tags.filter { $0 == SmartTag(kind: .documentType, value: "合同") }.count == 1)
    }
}
