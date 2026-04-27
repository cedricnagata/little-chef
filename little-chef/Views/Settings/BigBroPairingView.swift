//
//  BigBroPairingView.swift
//  little-chef
//

import SwiftUI
import BigBroKit

struct BigBroPairingView: View {
    @ObservedObject var client: BigBroClient

    @State private var discovered: [BigBroDevice] = []
    @State private var isDiscovering = false
    @State private var isPairing = false
    @State private var error: String? = nil

    var body: some View {
        Group {
            // Connection status row
            HStack(spacing: 10) {
                Circle()
                    .fill(client.isConnected ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)

                if client.isConnected, let device = client.connectedDevice {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.name)
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text("Connected")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Disconnect") {
                        client.disconnect()
                        discovered = []
                        error = nil
                    }
                    .font(.caption)
                    .fontWeight(.medium)
                    .buttonStyle(.bordered)
                    .foregroundStyle(.red)
                } else {
                    Text("Not connected")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !isDiscovering && !isPairing {
                        Button("Find Devices") {
                            Task { await startDiscovery() }
                        }
                        .font(.caption)
                        .fontWeight(.medium)
                        .buttonStyle(.bordered)
                        .tint(.orange)
                    }
                }
            }

            if isDiscovering {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text("Scanning for BigBro hosts…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !discovered.isEmpty && !client.isConnected {
                ForEach(discovered) { device in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name).font(.subheadline)
                            Text("\(device.host):\(device.port)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Pair") {
                            Task { await pair(with: device) }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .font(.caption)
                        .disabled(isPairing)
                    }
                }
            }

            if isPairing {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text("Waiting for Mac approval…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Live model-download progress from the Mac
            if !client.modelDownloads.isEmpty {
                ForEach(Array(client.modelDownloads.values), id: \.model) { progress in
                    ModelDownloadRow(progress: progress)
                }
            }

            // Connection-state hint when reconnecting
            if client.connectionState == .reconnecting {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text("Reconnecting…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Auto-reconnect toggle once we have at least one paired Mac on file
            if !client.pairedDeviceNames.isEmpty {
                Toggle(isOn: Binding(
                    get: { client.autoReconnectEnabled },
                    set: { newValue in
                        if newValue { client.enableAutoReconnect() } else { client.disableAutoReconnect() }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Auto-reconnect")
                            .font(.subheadline)
                        Text("Reconnects to a paired Mac automatically")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(.orange)
            }

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
    }

    // MARK: - Actions

    private func startDiscovery() async {
        error = nil
        discovered = []
        isDiscovering = true
        discovered = await client.discover()
        isDiscovering = false
    }

    private func pair(with device: BigBroDevice) async {
        isPairing = true
        error = nil
        do {
            let approved = try await client.pair(with: device)
            if approved {
                discovered = []
                // Opt into auto-reconnect on first successful pair so future launches
                // (and dropped connections) reconnect silently.
                client.enableAutoReconnect()
            } else {
                error = "Pairing was denied on the Mac."
            }
        } catch {
            self.error = error.localizedDescription
        }
        isPairing = false
    }
}

// MARK: - Model Download Row

private struct ModelDownloadRow: View {
    let progress: ModelDownloadProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if progress.done {
                    Image(systemName: progress.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(progress.success ? .green : .red)
                        .font(.caption)
                } else {
                    ProgressView().scaleEffect(0.7)
                }
                Text(progress.model)
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer()
                if !progress.done && progress.bytesTotal > 0 {
                    Text("\(Int(progress.percent * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if !progress.done {
                ProgressView(value: progress.bytesTotal > 0 ? progress.percent : 0)
                    .tint(.orange)
                Text(progress.status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let err = progress.error, !progress.success {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }
}
