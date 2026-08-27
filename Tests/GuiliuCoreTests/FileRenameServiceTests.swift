import Foundation
import Testing
@testable import GuiliuCore

@Suite("文件重命名")
struct FileRenameServiceTests {
    @Test("重命名只修改主文件名并保留扩展名")
    func preservesExtension() throws {
        let fixture = try RenameFixture()
        defer { fixture.remove() }
        let source = fixture.directory.appendingPathComponent("旧名称.PDF")
        try Data("paper".utf8).write(to: source)

        let destination = try FileRenameService().rename(
            file: source,
            toBaseName: "新名称",
            in: fixture.directory
        )

        #expect(destination.lastPathComponent == "新名称.PDF")
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try Data(contentsOf: destination) == Data("paper".utf8))
    }

    @Test("同名文件不会被覆盖")
    func avoidsOverwrite() throws {
        let fixture = try RenameFixture()
        defer { fixture.remove() }
        let source = fixture.directory.appendingPathComponent("原名.pdf")
        let existing = fixture.directory.appendingPathComponent("论文.pdf")
        try Data("new".utf8).write(to: source)
        try Data("existing".utf8).write(to: existing)

        let destination = try FileRenameService().rename(
            file: source,
            toBaseName: "论文",
            in: fixture.directory
        )

        #expect(destination.lastPathComponent == "论文 2.pdf")
        #expect(try Data(contentsOf: existing) == Data("existing".utf8))
    }

    @Test("拒绝路径字符和允许目录外文件")
    func rejectsUnsafeInput() throws {
        let fixture = try RenameFixture()
        defer { fixture.remove() }
        let source = fixture.directory.appendingPathComponent("安全.docx")
        try Data().write(to: source)

        #expect(throws: FileRenameError.invalidName) {
            _ = try FileRenameService().rename(file: source, toBaseName: "../逃逸", in: fixture.directory)
        }
        #expect(throws: FileRenameError.outsideAllowedLocation) {
            _ = try FileRenameService().rename(
                file: source,
                toBaseName: "改名",
                in: fixture.root.appendingPathComponent("别处", isDirectory: true)
            )
        }
    }

    @Test("符号链接仅在明确允许时可重命名且目标不变")
    func renamesReferenceSafely() throws {
        let fixture = try RenameFixture()
        defer { fixture.remove() }
        let original = fixture.root.appendingPathComponent("微信原件.pdf")
        let reference = fixture.directory.appendingPathComponent("微信原件.pdf")
        try Data("original".utf8).write(to: original)
        try FileManager.default.createSymbolicLink(at: reference, withDestinationURL: original)

        let destination = try FileRenameService().rename(
            file: reference,
            toBaseName: "会议资料",
            in: fixture.directory,
            allowSymbolicLink: true
        )

        #expect(destination.lastPathComponent == "会议资料.pdf")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path) == original.path)
        #expect(try Data(contentsOf: original) == Data("original".utf8))
    }
}

private struct RenameFixture {
    let root: URL
    let directory: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GuiliuRename-\(UUID().uuidString)", isDirectory: true)
        directory = root.appendingPathComponent("Files", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
