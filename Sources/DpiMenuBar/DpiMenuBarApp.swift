import AppKit
import SwiftUI

@main
struct DpiMenuBarApp: App {
    @StateObject private var model = DpiViewModel()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra("DPI", systemImage: "cursorarrow") {
            ContentView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct ContentView: View {
    @ObservedObject var model: DpiViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Mouse")
                Spacer()
                Button("Refresh") {
                    model.refresh()
                }
            }

            Picker("Mouse", selection: $model.selectedDeviceID) {
                ForEach(model.devices) { device in
                    Text(device.displayName).tag(Optional(device.id))
                }
            }
            .pickerStyle(.menu)
            .disabled(model.devices.isEmpty)

            if model.isDpiAvailable {
                VStack(alignment: .leading, spacing: 6) {
                    Text("DPI: \(model.selectedDpi ?? 0)")
                    Slider(
                        value: $model.dpiIndex,
                        in: 0...Double(max(model.dpiChoices.count - 1, 0)),
                        step: 1
                    ) { editing in
                        if !editing {
                            model.commitDpi()
                        }
                    }
                    .disabled(model.dpiChoices.isEmpty)
                }
            } else {
                Text("DPI control not available")
                    .foregroundColor(.secondary)
            }

            if !model.status.isEmpty {
                Text(model.status)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .frame(width: 260)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }
}
