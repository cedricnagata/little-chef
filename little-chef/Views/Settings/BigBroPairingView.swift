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
            } else {
                error = "Pairing was denied on the Mac."
            }
        } catch {
            self.error = error.localizedDescription
        }
        isPairing = false
    }
}
