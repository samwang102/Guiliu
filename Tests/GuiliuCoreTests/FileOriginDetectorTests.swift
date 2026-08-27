import Testing
@testable import GuiliuCore

@Suite("文件来源识别")
struct FileOriginDetectorTests {
    @Test("解析常用 App 写入的隔离属性")
    func parsesKnownQuarantineAgents() {
        #expect(FileOriginDetector.parseQuarantineAgent("0081;66f2d190;WeChat;") == .wechat)
        #expect(FileOriginDetector.parseQuarantineAgent("0081;66f2d190;QQ;") == .qq)
        #expect(FileOriginDetector.parseQuarantineAgent("0081;66f2d190;Lark;") == .feishu)
        #expect(FileOriginDetector.parseQuarantineAgent("0081;66f2d190;Safari;") == .safari)
    }

    @Test("未知或不完整的隔离属性不伪造来源")
    func rejectsUnknownQuarantineAgents() {
        #expect(FileOriginDetector.parseQuarantineAgent("0081;66f2d190;Google Chrome;") == nil)
        #expect(FileOriginDetector.parseQuarantineAgent("invalid") == nil)
    }
}
