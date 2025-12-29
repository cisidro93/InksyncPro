import SwiftUI

struct SettingsView: View {
    @AppStorage("email") var email: String = ""
    @AppStorage("kindle_email") var kindleEmail: String = ""
    
    var body: some View {
        Form {
            Section(header: Text("Kindle Configuration")) {
                TextField("Your Email", text: $email)
                    .autocapitalization(.none)
                TextField("Kindle Email", text: $kindleEmail)
                    .autocapitalization(.none)
            }
            
            Section {
                Button("Save Configuration") {
                    // Save action logic if needed
                }
            }
        }
        .navigationTitle("Settings")
    }
}
