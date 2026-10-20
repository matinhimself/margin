import SwiftUI

struct ConnectionView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var server = ""
    @State private var token = ""
    @State private var connecting = false
    @State private var failure: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Your library server") {
                    TextField("Server URL", text: $server).autocorrectionDisabled()
                    SecureField("Access token (if configured)", text: $token)
                    Text("On this Mac or a simulator, use http://127.0.0.1:8787. On an iPhone or iPad, enter your Mac’s local network address, such as http://192.168.1.20:8787.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Made for your own library") {
                    Text("Books download automatically for offline reading. Progress, saved books, bookmarks, notes, highlights, and reading habits sync through this server. Offline edits queue locally and upload when you reconnect. Devices using the same server share one personal library.")
                    Text("The access token is stored in Keychain. Use a trusted local network for HTTP connections.").font(.caption).foregroundStyle(.secondary)
                }
                if let failure { Section { Text(failure).foregroundStyle(.red) } }
            }.formStyle(.grouped).navigationTitle("Connection")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(connecting) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(connecting ? "Connecting…" : "Connect") {
                            connecting = true; failure = nil
                            Task {
                                do { try await store.connect(server: server, token: token); dismiss() }
                                catch { failure = error.localizedDescription }
                                connecting = false
                            }
                        }.disabled(connecting || store.isLoading || store.isSyncing)
                    }
                }.disabled(connecting)
        }
        .frame(minWidth: 320, idealWidth: 540, minHeight: 400, idealHeight: 480)
        .onAppear { server = store.server; token = store.token }
        .interactiveDismissDisabled(connecting)
    }
}
