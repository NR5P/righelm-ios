import RigHelmCore
import SwiftUI

/// Pick a RigHelm station: the ones heard on the LAN, saved ones, or one
/// typed in by address.
struct ConnectView: View {
    @Environment(RigController.self) private var rig
    @State private var asking: SavedServer?
    @State private var addingManually = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 10) {
                        Image("Logo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 110, height: 110)
                            .shadow(color: Theme.amber.opacity(0.25), radius: 18)
                        Text("RigHelm")
                            .font(.system(size: 30, weight: .bold))
                        Text("Control your RigHelm station from your phone")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }

                if let err = rig.lastError {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.red)
                    }
                }

                Section {
                    if rig.discovered.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Looking for RigHelm on your network…")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(rig.discovered) { b in
                        Button {
                            asking = SavedServer(name: b.name, host: b.host, port: b.port)
                        } label: {
                            BeaconRow(beacon: b)
                        }
                    }
                } header: {
                    Text("On your network")
                } footer: {
                    Text("Stations appear here when RigHelm on the radio's computer has “Let other computers use this radio” turned on.")
                }

                let others = rig.saved.filter { s in !rig.discovered.contains { $0.host == s.host && $0.port == s.port } }
                if !others.isEmpty {
                    Section("Saved") {
                        ForEach(others) { s in
                            Button {
                                asking = s
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.name).foregroundStyle(.primary)
                                    Text("\(s.host):\(String(s.port)) · not heard right now")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions {
                                Button("Forget", role: .destructive) { rig.forget(s) }
                            }
                        }
                    }
                }

                Section {
                    Button {
                        addingManually = true
                    } label: {
                        Label("Connect by address", systemImage: "network")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .refreshable { rig.refreshDiscovery() }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $asking) { server in
                ConnectSheet(server: server, editableAddress: false)
            }
            .sheet(isPresented: $addingManually) {
                ConnectSheet(server: SavedServer(name: "", host: "", port: RemoteProtocol.controlPort), editableAddress: true)
            }
        }
    }
}

struct BeaconRow: View {
    let beacon: ServerBeacon

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.title2)
                .foregroundStyle(beacon.radio == "connected" ? Theme.amber : Theme.dim)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(beacon.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("\(beacon.host) · \(radioText)")
                    .font(.caption)
                    .foregroundStyle(beacon.radio == "connected" ? Theme.green : .secondary)
            }
            Spacer()
            if beacon.mic {
                Image(systemName: "mic.fill").foregroundStyle(.secondary).help("Accepts microphone audio")
            }
            Image(systemName: beacon.auth ? "lock.fill" : "lock.open")
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var radioText: String {
        switch beacon.radio {
        case "connected": return "radio on"
        case "not-answering": return "radio not answering"
        default: return "no radio"
        }
    }
}

/// Password (and, for a typed-in station, its address), then connect.
struct ConnectSheet: View {
    @Environment(RigController.self) private var rig
    @Environment(\.dismiss) private var dismiss
    @State var server: SavedServer
    let editableAddress: Bool
    @State private var password = ""
    @State private var port = ""

    var body: some View {
        NavigationStack {
            Form {
                if editableAddress {
                    Section("Station") {
                        TextField("Address (e.g. 192.168.1.20)", text: $server.host)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Port", text: $port)
                            .keyboardType(.numberPad)
                    }
                } else {
                    Section {
                        LabeledContent("Station", value: server.name)
                        LabeledContent("Address", value: "\(server.host):\(String(server.port))")
                    }
                }
                Section {
                    SecureField("Password", text: $password)
                        .submitLabel(.go)
                        .onSubmit(connect)
                } footer: {
                    Text("The password set in RigHelm under Remote (LAN). Without one, a station lets you listen and tune but never transmit.")
                }
                Section {
                    Button(action: connect) {
                        Text("Connect").frame(maxWidth: .infinity).fontWeight(.semibold)
                    }
                    .disabled(server.host.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle(editableAddress ? "Connect by address" : "Connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onAppear {
                port = String(server.port)
                password = rig.savedPassword(for: server) ?? ""
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func connect() {
        var s = server
        s.host = s.host.trimmingCharacters(in: .whitespaces)
        guard !s.host.isEmpty else { return }
        if editableAddress {
            s.port = UInt16(port) ?? RemoteProtocol.controlPort
            if s.name.isEmpty { s.name = s.host }
        }
        rig.connect(s, password: password)
        dismiss()
    }
}
