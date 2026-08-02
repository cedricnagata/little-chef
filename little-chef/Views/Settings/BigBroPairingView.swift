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
            if client.pairedDeviceNames.isEmpty && !client.isConnected {
                bigBroSetupInstructions
            }

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

            // Models LittleChef asked for that the Mac doesn't have yet. Not an error: the
            // first question starts the download, and the progress rows below then report it.
            if client.isConnected && !client.missingModels.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Not downloaded on this Mac yet", systemImage: "arrow.down.circle")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.orange)
                    ForEach(client.missingModels, id: \.self) { model in
                        Text(model)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospaced()
                    }
                    Text("Your first question will start the download — or download it in BigBro's Settings on the Mac.")
                        .font(.caption2)
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

    // MARK: - Setup Instructions

    private var bigBroSetupInstructions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("What is BigBro?", systemImage: "desktopcomputer")
                .font(.subheadline)
                .fontWeight(.semibold)

            Text("BigBro is a free Mac app that runs an AI model locally on your Mac and shares it with LittleChef over Wi-Fi. This lets any iPhone use the cooking assistant without downloading a model on-device.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                SetupStep(number: 1, text: "Download and install BigBro on your Mac")
                SetupStep(number: 2, text: "Open BigBro and download gpt-oss 20B in its Settings (LittleChef will also start the download on your first question)")
                SetupStep(number: 3, text: "Make sure your iPhone and Mac are on the same Wi-Fi network")
                SetupStep(number: 4, text: "Tap \"Find Devices\" below and select your Mac")
                SetupStep(number: 5, text: "Approve the connection request on your Mac")
            }

            Link(destination: URL(string: "https://www.cedricnagata.com/projects#bigbro")!) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                    Text("Download BigBro for Mac")
                        .fontWeight(.medium)
                }
                .font(.caption)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.15))
                .foregroundStyle(.orange)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.vertical, 4)
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

// MARK: - Setup Step

private struct SetupStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Color.orange)
                .clipShape(Circle())
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
