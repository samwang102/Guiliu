import Foundation
import SwiftUI

@main
struct GuiliuApp: App {
    @State private var model: AppModel

    init() {
        if let suiteName = ProcessInfo.processInfo.environment["GUILIU_DEFAULTS_SUITE"],
           let isolatedDefaults = UserDefaults(suiteName: suiteName) {
            _model = State(initialValue: AppModel(defaults: isolatedDefaults))
        } else {
            _model = State(initialValue: AppModel(defaults: .standard))
        }
    }

    var body: some Scene {
        WindowGroup("归流") {
            ContentView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 600)
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(after: .newItem) {
                Button("文件搜索") {
                    model.requestSearchFocus()
                }
                .keyboardShortcut("f", modifiers: .command)

                Button("关闭预览或解读") {
                    model.closeContextReader()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(model.filePreviewURL == nil && model.aiAnalysisReader == nil)

                Button("扫描现有文件") {
                    model.importExistingFiles()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.isImportingExistingFiles)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .frame(width: 620, height: 430)
        }
    }
}
