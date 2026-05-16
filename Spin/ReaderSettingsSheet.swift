import SwiftUI

struct ReaderSettingsSheet: View {
    @ObservedObject var settings: ReaderSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ReaderAppearanceSettingsContent(
            settings: settings,
            dismissAction: { dismiss() }
        )
        .presentationDetents([.height(640)])
        .presentationBackground(Color.black)
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }
}

struct ReaderAppearanceSettingsView: View {
    @EnvironmentObject private var settings: ReaderSettings

    var body: some View {
        ReaderAppearanceSettingsContent(settings: settings)
            .navigationTitle("Appearance")
            .navigationBarTitleDisplayMode(.inline)
            .darkNavigationBar()
            .preferredColorScheme(.dark)
    }
}

private struct ReaderAppearanceSettingsContent: View {
    @ObservedObject var settings: ReaderSettings
    var dismissAction: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let dismissAction {
                HStack {
                    Text("Reader")
                        .font(.custom("DMSans-Bold", size: 17))
                        .tracking(-0.4)
                        .foregroundColor(.white)
                    Spacer()
                    Button(action: dismissAction) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.white.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                }
            }

            sizeSection
            optionSection("Font", options: ReaderFontFamily.allCases, selection: $settings.fontFamily, label: \.label)
            optionSection("Line spacing", options: ReaderLineSpacing.allCases, selection: $settings.lineSpacing, label: \.label)
            optionSection("Margins", options: ReaderMargins.allCases, selection: $settings.margins, label: \.label)
            aiQuestionsToggle
            brightnessSection

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.black.ignoresSafeArea())
    }

    private var sizeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Size", trailing: "\(Int(settings.fontSize))pt")
            HStack(spacing: 12) {
                Text("A")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.45))
                Slider(value: $settings.fontSize, in: 14...28, step: 1)
                    .tint(.white.opacity(0.9))
                Text("A")
                    .font(.system(size: 22))
                    .foregroundColor(.white.opacity(0.45))
            }
        }
    }

    private func optionSection<Option: Hashable & Identifiable>(
        _ title: String,
        options: [Option],
        selection: Binding<Option>,
        label: KeyPath<Option, String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(title)
            segmentedControl(options: options, selection: selection, label: label)
        }
    }

    private var aiQuestionsToggle: some View {
        HStack {
            Text("AI Questions")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.white.opacity(0.55))
            Spacer()
            Toggle("", isOn: $settings.showAIQuestions)
                .labelsHidden()
                .tint(.white.opacity(0.6))
        }
    }

    private var brightnessSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Brightness")
            HStack(spacing: 12) {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.45))
                Slider(value: $settings.dimLevel, in: 0...0.7)
                    .tint(.white.opacity(0.9))
                Image(systemName: "moon.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.45))
            }
        }
    }

    @ViewBuilder
    private func sectionHeader(_ title: String, trailing: String? = nil) -> some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.white.opacity(0.55))
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.55))
            }
        }
    }

    private func segmentedControl<Option: Hashable & Identifiable>(
        options: [Option],
        selection: Binding<Option>,
        label: KeyPath<Option, String>
    ) -> some View {
        HStack(spacing: 6) {
            ForEach(options) { option in
                let isSelected = selection.wrappedValue == option
                Button {
                    selection.wrappedValue = option
                } label: {
                    Text(option[keyPath: label])
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(isSelected ? .black : .white.opacity(0.75))
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(isSelected ? Color.white.opacity(0.92) : Color.white.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}
