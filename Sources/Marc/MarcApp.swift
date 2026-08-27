import SwiftUI

@main
struct MarcApp: App {
    @StateObject private var store = DocumentStore()

    var body: some Scene {
        WindowGroup {
            WorkspaceView()
                .environmentObject(store)
                .frame(minWidth: 900, minHeight: 600)
                .onOpenURL { store.open(url: $0) }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") {
                    store.showOpenPanel()
                }
                .keyboardShortcut("o")

                Button("Save") {
                    store.saveSelected()
                }
                .keyboardShortcut("s")
                .disabled(store.selectedDocument == nil)

                Divider()

                Button("Close Tab") {
                    store.closeSelected()
                }
                .keyboardShortcut("w")
                .disabled(store.selectedDocument == nil)
            }

            CommandMenu("Text Size") {
                Button("Increase Text Size") {
                    store.adjustSelectedFontSize(by: 1)
                }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(store.selectedDocument == nil)

                Button("Decrease Text Size") {
                    store.adjustSelectedFontSize(by: -1)
                }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(store.selectedDocument == nil)

                Button("Actual Size") {
                    store.resetSelectedFontSize()
                }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(store.selectedDocument == nil)
            }
        }
    }
}
