//
//  BigBroPairingView.swift
//  little-chef
//

import SwiftUI
import BigBroKit

struct BigBroPairingView: View {
    let client: BigBroClient

    @State private var isPaired = false
    @State private var pairedDeviceName: String? = nil
    @State private var discovered: [BigBroDevice] = []
    @State private var isDiscovering = false
    @State private var isPairing = false
    @State private var pairingDeviceId: String? = nil
    @State private var error: String? = nil

    var body: some View {
        Group {
            // Connection status
            HStack {
                if isPaired {
                    Label("Connected to \(pairedDeviceName ?? "BigBro")", systemImage: "checkmark.shield.fill")
                        .foregroundColor(.green)
                        .font(.subheadline)
                } else {
                    Label("Not connected", systemImage: "shield.slash")
                        .foregroundColor(.secondary)
                        .font(.subheadline)
                }
                Spacer()
                if !isDiscovering && !isPairing {
                    Button(isPaired ? "Change" : "Find Devices") {
                        Task { await startDiscovery() }
                    }
                    .font(.caption)
                    .fontWeight(.medium)
                    .buttonStyle(.bordered)
                    .tint(.orange)
                }
            }

            if isDiscovering {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text("Scanning for BigBro hosts…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if !discovered.isEmpty && !isPairing {
                ForEach(discovered) { device in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name).font(.subheadline)
                            Text("\(device.host):\(device.port)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Pair") {
                            Task { await pair(with: device) }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .font(.caption)
                    }
                }
            }

            if isPairing {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text("Waiting for approval on Mac…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if let error {
                Text(error).font(.caption).foregroundColor(.red)
            }
        }
        .onAppear { checkPairingStatus() }
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
        pairingDeviceId = device.id
        error = nil
        do {
            let approved = try await client.pair(with: device)
            if approved {
                isPaired = true
                pairedDeviceName = device.name
                discovered = []
            } else {
                error = "Pairing was denied on the Mac."
            }
        } catch {
            self.error = error.localizedDescription
        }
        isPairing = false
        pairingDeviceId = nil
    }

    // MARK: - Status Check

    private func checkPairingStatus() {
        let stored = UserDefaults.standard.string(forKey: "bigbro.device.id")
        isPaired = stored != nil
        pairedDeviceName = UserDefaults.standard.string(forKey: "bigbro.device.name")
    }
}
