import SwiftUI
import SceneKit
import Quartz
import Metal
import AppKit
import UniformTypeIdentifiers

/// Root UI used inside the demo host macOS app.  Drop a .step file to view it.
struct QuickLookStepHostView: View {
    @State private var scene: SCNScene? = nil
    @State private var loadError: String? = nil
    @State private var isTargeted: Bool = false

    var body: some View {
        ZStack {
            if let scene {
                SceneKitView(scene: scene)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Drop a STEP file")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }

            if let loadError {
                VStack {
                    Spacer()
                    Text(loadError)
                        .foregroundStyle(.blue)
                        .padding()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity) // fill the window
        .contentShape(Rectangle()) // define hit-test area after sizing
        .onDrop(of: [UTType.fileURL, UTType.url, UTType.item], isTargeted: $isTargeted) { providers in
            var collected: [URL] = []
            let group = DispatchGroup()

            func load(_ provider: NSItemProvider, uti: String) {
                group.enter()
                provider.loadItem(forTypeIdentifier: uti, options: nil) { item, _ in
                    defer { group.leave() }
                    if let url = item as? URL {
                        collected.append(url)
                    } else if let path = item as? String {
                        collected.append(URL(fileURLWithPath: path))
                    }
                }
            }

            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    load(provider, uti: UTType.fileURL.identifier)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    load(provider, uti: UTType.url.identifier)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.item.identifier) {
                    load(provider, uti: UTType.item.identifier)
                }
            }

            group.notify(queue: .main) {
                if let first = collected.first {
                    loadStep(first)
                }
            }

            return true
        }
        .background(isTargeted ? Color.accentColor.opacity(0.2) : Color.clear)
        // Respond when the app is launched/opened with a file (Finder double-click, `open` CLI, etc.)
        .onOpenURL { url in
            guard url.isFileURL else { return }
            loadStep(url)
        }
    }

    // MARK: - Loading & snapshot
    private func loadStep(_ url: URL) {
        loadError = nil

        // If we’re running sandboxed, we need to open a security-scoped bookmark
        // before reading the file contents in Rust.
        let needsSecurity = url.startAccessingSecurityScopedResource()
        defer {
            if needsSecurity { url.stopAccessingSecurityScopedResource() }
        }

        do {
            print("Loading STEP at", url.path)
            scene = try SceneBuilder.scene(for: url)
        } catch {
            scene = nil
            loadError = error.localizedDescription
            print("Failed to load STEP:", error.localizedDescription)
        }
    }
}

// MARK: - Drag & Drop helper (legacy – unused) 
