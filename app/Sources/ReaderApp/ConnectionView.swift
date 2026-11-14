import SwiftUI
import LibraryCore

struct ConnectionView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var server = ""
    @State private var token = ""
    @State private var proxyKind: LibraryProxy.Kind = .system
    @State private var proxyHost = ""
    @State private var proxyPort = ""
    @State private var proxyUsername = ""
    @State private var proxyPassword = ""
    @State private var mode = "Access token"
    @State private var email = ""
    @State private var password = ""
    @State private var inviteCode = ""
    @State private var displayName = ""
    @State private var savingProfile = false
    @State private var creatingInvite = false
    @State private var generatedInvite: LibraryInvite?
    @State private var connecting = false
    @State private var failure: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Your library server") {
                    TextField("Server URL", text: $server).autocorrectionDisabled()
                    Picker("Connection method", selection: $mode) {
                        Text("Access token").tag("Access token")
                        Text("Sign in").tag("Sign in")
                        Text("Join with invite").tag("Join")
                    }
                    if mode == "Access token" { SecureField("Access token", text: $token) }
                    else {
                        TextField("Email", text: $email).autocorrectionDisabled()
                        SecureField("Password", text: $password)
                        if mode == "Join" {
                            TextField("Invite code", text: $inviteCode).autocorrectionDisabled()
                            TextField("Display name", text: $displayName)
                            Text("Your display name is shown on books you upload.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("Hosted library: https://books.0xff.shop:8443. For a local server on this Mac or a simulator, use http://127.0.0.1:8787.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Proxy") {
                    Picker("Proxy type", selection: $proxyKind) {
                        Text("System default").tag(LibraryProxy.Kind.system)
                        Text("HTTP").tag(LibraryProxy.Kind.http)
                        Text("SOCKS5").tag(LibraryProxy.Kind.socks5)
                    }
                    if proxyKind != .system {
                        TextField("Proxy host", text: $proxyHost).autocorrectionDisabled()
                        TextField("Proxy port", text: $proxyPort)
                        TextField("Username (optional)", text: $proxyUsername).autocorrectionDisabled()
                        SecureField("Password (optional)", text: $proxyPassword)
                    }
                    Text("The proxy applies to all library requests, including sign in, sync, uploads, and downloads.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let user = store.user {
                    Section("Your profile") {
                        Text(user.email.isEmpty ? "Library admin" : user.email)
                        TextField("Public display name", text: $displayName)
                        Text("This name is attributed to your future uploads. Your email is not shown on book pages.").font(.caption).foregroundStyle(.secondary)
                        Button(savingProfile ? "Saving…" : "Save display name") {
                            savingProfile = true; failure = nil
                            Task {
                                do {
                                    store.user = try await LibraryAPI(server: store.server, token: store.token, proxy: store.proxy).updateProfile(name: displayName)
                                } catch { failure = error.localizedDescription }
                                savingProfile = false
                            }
                        }.disabled(savingProfile || displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Sign out") { Task { await store.signOut(); token = ""; password = ""; dismiss() } }.disabled(store.isLoading || store.isSyncing)
                    }
                }
                if store.isAdmin {
                    Section("Invite people") {
                        Button(creatingInvite ? "Creating invite…" : "Generate invite code") {
                            creatingInvite = true; failure = nil
                            Task {
                                do {
                                    generatedInvite = try await LibraryAPI(server: store.server, token: store.token, proxy: store.proxy).createInvite()
                                } catch { failure = error.localizedDescription }
                                creatingInvite = false
                            }
                        }.disabled(creatingInvite)
                        if let invite = generatedInvite {
                            Text(invite.code).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            Text("Single use · expires \(Date(timeIntervalSince1970: TimeInterval(invite.expiresAt)), style: .date). Copy it now; the server only shows a code when it is created.")
                                .font(.caption).foregroundStyle(.secondary)
                            ShareLink("Share invite code", item: invite.code)
                        }
                    }
                }
                Section("Made for your own library") {
                    Text("Books download automatically for offline reading. Progress, saved books, bookmarks, notes, highlights, and reading habits sync through this server. Offline edits queue locally and upload when you reconnect. Users share the bookshelf. Notes, highlights, and reading progress belong to the signed-in account.")
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
                                do {
                                    let selectedProxy = try LibraryProxy(kind: proxyKind, host: proxyHost, port: Int(proxyPort) ?? 0,
                                                                         username: proxyUsername, password: proxyPassword).validated()
                                    var credential = token
                                    if mode != "Access token" {
                                        let session = try await LibraryAPI(server: server, token: "", proxy: selectedProxy).login(email: email, password: password, inviteCode: mode == "Join" ? inviteCode : nil)
                                        credential = session.token
                                        if mode == "Join" { _ = try await LibraryAPI(server: server, token: credential, proxy: selectedProxy).updateProfile(name: displayName) }
                                    }
                                    try await store.connect(server: server, token: credential, proxy: selectedProxy); password = ""; dismiss()
                                }
                                catch { failure = error.localizedDescription }
                                connecting = false
                            }
                        }.disabled(connecting || store.isLoading || store.isSyncing || (mode == "Join" && displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                    }
                }.disabled(connecting)
        }
        .frame(minWidth: 320, idealWidth: 540, minHeight: 400, idealHeight: 480)
        .onAppear {
            server = store.server; token = store.token; displayName = store.user?.displayName ?? ""
            proxyKind = store.proxy.kind; proxyHost = store.proxy.host; proxyPort = store.proxy.port == 0 ? "" : String(store.proxy.port)
            proxyUsername = store.proxy.username; proxyPassword = store.proxy.password
        }
        .interactiveDismissDisabled(connecting)
    }
}
