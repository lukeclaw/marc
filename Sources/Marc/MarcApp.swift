import AppKit
import MarcCore
import SwiftUI

/// marc manages its own in-app tabs, so macOS window tabbing is turned off.
/// It contributes a Show Tab Bar item that claims ⇧⌘T and a set of window
/// commands that do nothing useful here.
final class MarcAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }
}

@main
struct MarcApp: App {
    @NSApplicationDelegateAdaptor(MarcAppDelegate.self) private var appDelegate
    @StateObject private var store = DocumentStore()
    @AppStorage("workspaceMode") private var mode: WorkspaceMode = .rendered
    @AppStorage("tocPosition") private var tocPosition: SidebarPosition = .left
    @AppStorage("showTableOfContents") private var showTableOfContents = true
    @AppStorage("showLinkedFiles") private var showLinkedFiles = false

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
                Button("New Markdown File…") {
                    store.newDocument(format: .markdown)
                }
                .keyboardShortcut("n")

                Button("New HTML File…") {
                    store.newDocument(format: .html)
                }
                .keyboardShortcut("n", modifiers: [.command, .option])

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

            CommandGroup(after: .sidebar) {
                Button(showTableOfContents ? "Hide Outline" : "Show Outline") {
                    showTableOfContents.toggle()
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])

                Button(showLinkedFiles ? "Hide Linked Files" : "Show Linked Files") {
                    showLinkedFiles.toggle()
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])

                Divider()

                Picker("Outline Position", selection: $tocPosition) {
                    Text("Left").tag(SidebarPosition.left)
                    Text("Right").tag(SidebarPosition.right)
                }

                Picker("Document View", selection: $mode) {
                    ForEach(WorkspaceMode.allCases) { item in
                        Text(item.label).tag(item)
                    }
                }

                Divider()
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
