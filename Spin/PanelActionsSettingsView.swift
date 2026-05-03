import SwiftUI

// MARK: - Panel Actions List

struct PanelActionsSettingsView: View {
    @EnvironmentObject var readerSettings: ReaderSettings
    @State private var editingAction: PanelAction?
    @State private var isAddingNew = false

    var body: some View {
        List {
            actionsSection
            if readerSettings.panelActions.count < PanelAction.maxCount {
                addButtonSection
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.automatic)
        .navigationTitle("AI Actions")
        .navigationBarTitleDisplayMode(.automatic)
        .sheet(item: $editingAction) { action in
            PanelActionEditView(action: action) { updated in
                if let idx = readerSettings.panelActions.firstIndex(where: { $0.id == updated.id }) {
                    readerSettings.panelActions[idx] = updated
                }
            }
        }
        .sheet(isPresented: $isAddingNew) {
            PanelActionEditView(action: PanelAction(name: "", prompt: "")) { newAction in
                readerSettings.panelActions.append(newAction)
            }
        }
    }

    private var actionsSection: some View {
        Section {
            ForEach(readerSettings.panelActions) { action in
                Button {
                    editingAction = action
                } label: {
                    HStack(spacing: 12) {
                        Text(action.name)
                            .font(.body)
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if readerSettings.panelActions.count > 1 {
                        Button(role: .destructive) {
                            withAnimation {
                                readerSettings.panelActions.removeAll { $0.id == action.id }
                            }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .onMove { from, to in
                readerSettings.panelActions.move(fromOffsets: from, toOffset: to)
            }
        } header: {
            Text("\(readerSettings.panelActions.count)/\(PanelAction.maxCount) Actions")
        } footer: {
            Text("Swipe left to delete. Touch and hold to reorder.")
        }
    }

    @ViewBuilder
    private var addButtonSection: some View {
        Section {
            Button {
                isAddingNew = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                    Text("Add Action")
                }
                .foregroundStyle(.tint)
                .contentShape(Rectangle())
            }
        }
    }
}

// MARK: - Panel Action Edit View

struct PanelActionEditView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var prompt: String
    private let originalID: UUID
    private let onSave: (PanelAction) -> Void

    init(action: PanelAction, onSave: @escaping (PanelAction) -> Void) {
        _name = State(initialValue: action.name)
        _prompt = State(initialValue: action.prompt)
        self.originalID = action.id
        self.onSave = onSave
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var nameCharCount: Int { name.count }
    private var isNameAtLimit: Bool { nameCharCount >= PanelAction.maxNameLength }

    var body: some View {
        NavigationStack {
            List {
                nameSection
                promptSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.automatic)
            .navigationTitle("Edit Action")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let saved = PanelAction(
                            id: originalID,
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                        onSave(saved)
                        dismiss()
                    }
                    .disabled(!isValid)
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private var nameSection: some View {
        Section {
            HStack {
                TextField("e.g. Summarize this", text: $name)
                    .onChange(of: name) { _, newValue in
                        if newValue.count > PanelAction.maxNameLength {
                            name = String(newValue.prefix(PanelAction.maxNameLength))
                        }
                    }
                Spacer()
                Text("\(nameCharCount)/\(PanelAction.maxNameLength)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(isNameAtLimit ? .orange : .secondary)
            }
        } header: {
            fieldHeader("Label", helper: "Shown on the reader action button.")
        } footer: {
            EmptyView()
        }
    }

    private var promptSection: some View {
        Section {
            TextEditor(text: $prompt)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .frame(minHeight: 120)
        } header: {
            fieldHeader("Prompt", helper: "Visible text and book details are added automatically.")
        } footer: {
            EmptyView()
        }
    }

    private func fieldHeader(_ title: String, helper: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(helper)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
            .textCase(nil)
    }
}
