import SwiftUI
import WebKit

struct OllamaLoginView: View {
    @StateObject private var controller = OllamaLoginController()
    @Environment(\.dismiss) private var dismiss

    var onResult: (OllamaLoginResult) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sign In to Ollama")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            WebBrowserView(controller: controller)
                .frame(minHeight: 400)

            if let error = controller.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            } else if let status = controller.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
        }
        .frame(width: 500, height: 520)
        .onChange(of: controller.loginResult) { _, result in
            guard let result else { return }
            onResult(result)
            dismiss()
        }
        .onDisappear {
            controller.stopPolling()
        }
    }
}

private struct WebBrowserView: NSViewRepresentable {
    let controller: OllamaLoginController

    func makeNSView(context: Context) -> WKWebView {
        controller.makeWebView()
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
