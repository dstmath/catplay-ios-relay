import SwiftUI

struct ContentView: View {
    @ObservedObject var model: RelayViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Raspberry Pi signer") {
                    TextField("Host or IP", text: $model.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(model.isRunning)
                    TextField("Port", text: $model.portText)
                        .keyboardType(.numberPad)
                        .disabled(model.isRunning)
                }

                Section("Relay") {
                    LabeledContent("State", value: model.stateLabel)
                    LabeledContent("Android", value: model.androidConnected ? "Connected" : "Not connected")
                    LabeledContent("In-flight request", value: model.hasInFlightRequest ? "Yes" : "No")

                    Button(model.isRunning ? "Stop relay" : "Start relay") {
                        if model.isRunning {
                            model.stop(reason: "user_requested")
                        } else {
                            model.start()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(model.isRunning ? .red : .blue)
                }

                Section("Required order") {
                    Text("1. Keep this app open and tap Start relay.")
                    Text("2. Wait for the Android Carlink app to connect over BLE.")
                    Text("3. Start direct-USB CarPlay on Android.")
                    Text("The MFi certificate and challenge are forwarded unchanged to the configured Pi. Audio and video never pass through this app.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Diagnostics") {
                    if model.entries.isEmpty {
                        Text("No events yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.entries.reversed()) { entry in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.message)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("CatPlay MFi Relay")
        }
    }
}
