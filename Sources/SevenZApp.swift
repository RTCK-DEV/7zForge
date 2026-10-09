import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let serviceProvider = ServiceProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = serviceProvider
        NSUpdateDynamicServices()
    }
}

@main
struct SevenZApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        let a = CommandLine.arguments
        if a.contains("--mcp") {
            MCPServer.run()
        }
        if a.contains("--selftest") || a.contains("--dump-tokens") || a.contains("--z7x-write") || a.contains("--z7x-decode") {
            SelfTest.run()
        }
    }

    var body: some Scene {
        // 単一ウィンドウ運用: `open`/サービス起動のたびに新規ウィンドウが開く WindowGroup を避ける
        Window("7zip for mac byRTCK", id: "main") {
            ContentView()
                .frame(minWidth: 720, minHeight: 540)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("アーカイブを開く…") { AppState.shared.requestOpenArchive() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandMenu("タブ") {
                Button("圧縮") { AppState.shared.tab = 0 }
                    .keyboardShortcut("1", modifiers: .command)
                Button("解凍 / 一覧") { AppState.shared.tab = 1 }
                    .keyboardShortcut("2", modifiers: .command)
                Button("CPUベンチ") { AppState.shared.tab = 2 }
                    .keyboardShortcut("3", modifiers: .command)
                Button("GPU実験") { AppState.shared.tab = 3 }
                    .keyboardShortcut("4", modifiers: .command)
            }
        }
    }
}
