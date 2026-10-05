import AppKit
import CatonCore
import SwiftUI

/// One editable list of machine-account logins.
struct LoginSection: View {
    let session: Session
    let list: Session.LoginList
    let title: String
    let footer: String
    @State private var login = ""

    var body: some View {
        Section {
            ForEach(session.logins(list), id: \.self) { login in
                HStack {
                    Text(login)
                    Spacer()
                    Button("Remove") { session.removeLogin(login, from: list) }
                }
            }
            HStack {
                TextField("Login", text: $login).onSubmit(add)
                Button("Add", action: add).disabled(login.isEmpty)
            }
        } header: {
            Text(title)
        } footer: {
            Text(footer)
        }
    }

    private func add() {
        session.addLogin(login, to: list)
        login = ""
    }
}
