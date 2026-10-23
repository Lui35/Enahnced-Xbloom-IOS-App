import SwiftUI
import UIKit

struct RecipeLinkShareSheet: View {
    @Environment(\.dismiss) private var dismiss
    let recipeName: String
    let url: URL
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ZStack {
                StudioBackground()
                VStack(alignment: .leading, spacing: 20) {
                    Label("Share this recipe", systemImage: "square.and.arrow.up")
                        .font(.title2.bold())
                    Text(recipeName).font(.headline).foregroundStyle(StudioTheme.accent)
                    Text("Send a snapshot of this recipe. Anyone with the link and xBloom can preview it and save a copy. No account or internet connection is needed.")
                        .foregroundStyle(StudioTheme.muted)
                    Text("Your bean inventory, brew history, and favorite status aren’t included. Later edits won’t change this link.")
                        .font(.footnote).foregroundStyle(StudioTheme.muted)
                    ShareLink(item: url, subject: Text(recipeName), message: Text("Open this recipe in xBloom.")) {
                        Label("Share recipe link", systemImage: "square.and.arrow.up")
                            .font(.headline).foregroundStyle(.black)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(StudioTheme.accent, in: Capsule())
                    }.buttonStyle(.plain)
                    Button {
                        UIPasteboard.general.url = url
                        copied = true
                    } label: {
                        Label(copied ? "Link copied" : "Copy link", systemImage: copied ? "checkmark" : "link")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.bordered)
                    Text("If a messaging app doesn’t make the link tappable, paste it into Settings → Import recipe link in xBloom.")
                        .font(.caption).foregroundStyle(StudioTheme.muted)
                }.padding(22)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
}
