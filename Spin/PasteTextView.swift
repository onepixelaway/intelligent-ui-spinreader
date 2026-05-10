import SwiftUI
import UIKit

struct PasteTextView: View {
    let onSave: (String, String) -> Void
    let onCancel: () -> Void

    @State private var title: String = ""
    @State private var content: String = ""
    @State private var didPrefill = false
    @FocusState private var bodyFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    TextField("", text: $title, prompt: titlePrompt)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .tint(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)

                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 0.5)

                    ZStack(alignment: .topLeading) {
                        if content.isEmpty {
                            Text("Paste markdown or plain text…")
                                .font(.system(size: 15))
                                .foregroundColor(.white.opacity(0.3))
                                .padding(.horizontal, 16)
                                .padding(.top, 12)
                                .allowsHitTesting(false)
                        }

                        TextEditor(text: $content)
                            .font(.system(size: 15))
                            .foregroundColor(.white)
                            .tint(.white)
                            .scrollContentBackground(.hidden)
                            .background(Color.black)
                            .padding(.horizontal, 11)
                            .padding(.top, 4)
                            .focused($bodyFocused)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Paste Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { onCancel() }
                        .foregroundColor(.white.opacity(0.85))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { onSave(title, content) }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(canSave ? .white : .white.opacity(0.3))
                        .disabled(!canSave)
                }
            }
            .darkNavigationBar()
        }
        .preferredColorScheme(.dark)
        .onAppear {
            guard !didPrefill else { return }
            didPrefill = true
            if let pasted = clipboardText() {
                content = pasted
            }
            bodyFocused = true
        }
    }

    private var titlePrompt: Text {
        Text("Title (optional)")
            .foregroundColor(.white.opacity(0.3))
    }

    private var canSave: Bool {
        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func clipboardText() -> String? {
        let pb = UIPasteboard.general
        guard pb.hasStrings, let str = pb.string else { return nil }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : str
    }
}
