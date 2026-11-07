import CoreImage.CIFilterBuiltins
import SwiftUI

// MARK: - Paste an invite

/// "Have an invite link?": for links that didn't open the app (some chat apps don't make `photoshare://` tappable,
/// or the app was installed after the link was tapped). Accepts the link, the whole invite message, or the code.
///
/// The parsed code is handed back through `code`; the presenter routes it in the sheet's `onDismiss`, so the accept
/// sheet is never presented while this one is still animating away.
struct PasteInviteSheet: View {
    @Binding var code: String?
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var invalid = false
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            OttoColor.canvas.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(OttoColor.sage)
                        .accessibilityIdentifier("pasteInvite.cancel")
                    Spacer()
                }
                Text("Open an invite")
                    .font(OttoFont.serifBold(size: 26))
                    .foregroundStyle(OttoColor.ink)
                Text("Paste the link a friend sent you. The whole message works too.")
                    .font(.system(size: 15))
                    .foregroundStyle(OttoColor.bark)

                TextField("photoshare://invite/…", text: $text, axis: .vertical)
                    .lineLimit(1...4)
                    .font(.system(size: 15, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .padding(14)
                    .background(OttoColor.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(invalid ? OttoColor.wax : OttoColor.line, lineWidth: 1))
                    .accessibilityIdentifier("pasteInvite.field")
                    .onChange(of: text) { _, _ in invalid = false }

                // PasteButton reads the clipboard without the "Allow Paste" prompt.
                PasteButton(payloadType: String.self) { strings in
                    guard let first = strings.first else { return }
                    text = first
                    submit()
                }
                .buttonBorderShape(.capsule)
                .tint(OttoColor.sage)
                .accessibilityIdentifier("pasteInvite.paste")

                if invalid {
                    Text("That doesn't look like an otto invite. Ask your friend to send the link again.")
                        .font(.system(size: 13))
                        .foregroundStyle(OttoColor.wax)
                        .accessibilityIdentifier("pasteInvite.invalid")
                }

                Spacer()

                Button("Open invite") { submit() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("pasteInvite.open")
            }
            .padding(24)
        }
        .presentationDetents([.medium, .large])
    }

    private func submit() {
        if let parsed = InviteLink.code(fromPasted: text) {
            code = parsed
            dismiss()
        } else {
            invalid = true
        }
    }
}

// MARK: - QR code

/// The invite as a QR code, for adding someone who is standing next to you: their Camera app opens the link.
struct InviteQRCode: View {
    let url: URL

    var body: some View {
        if let image = Self.render(url.absoluteString) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(12)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .accessibilityLabel("Invite QR code")
                .accessibilityIdentifier("invite.qr")
        }
    }

    static func render(_ string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - Share message

enum InviteMessage {
    /// The text that goes with the link in Messages / WhatsApp. Spells out what happens so the link isn't a mystery.
    static func text(from name: String?) -> String {
        "\(name ?? "A friend") invited you to otto: when you're in each other's photos, you get them automatically. Tap the link to accept, or paste it into otto."
    }
}
