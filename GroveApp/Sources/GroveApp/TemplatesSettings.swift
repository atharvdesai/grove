import GroveKit
import SwiftUI

/// Your own note templates, next to the built-in ones.
///
/// A template only shapes notes whose rough notes imply no structure of their
/// own, so this is where "Interview" or "Sales discovery" gets the sections it
/// needs without every meeting having to be outlined by hand.
struct TemplatesSettings: View {
    @Environment(MeetingLibrary.self) private var library
    @ViewState private var selection: String?
    @ViewState private var draft = Draft()

    /// Edited as plain text, one section per line, and only turned back into a
    /// template on save — so a half-typed edit never reaches the enhancer.
    fileprivate struct Draft: Equatable {
        var name = ""
        var sections = ""
        var guidance = ""
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    Section("Built in") {
                        ForEach(NoteTemplate.builtIns) { template in
                            Label(template.name, systemImage: "lock").tag(template.id)
                        }
                    }
                    Section("Yours") {
                        ForEach(library.customTemplates) { template in
                            Text(template.name).tag(template.id)
                        }
                    }
                }
                HStack(spacing: 12) {
                    Button(action: add) { Image(systemName: "plus") }
                        .help("New template")
                    Button(action: deleteSelected) { Image(systemName: "minus") }
                        .disabled(selectedCustom == nil)
                        .help("Delete template")
                    Spacer()
                }
                .buttonStyle(.plain)
                .padding(8)
            }
            .frame(width: 180)

            Divider()

            Form {
                if let template = selectedTemplate {
                    if template.isBuiltIn {
                        LabeledContent("Sections", value: template.sections.joined(separator: ", "))
                        LabeledContent("Guidance") {
                            Text(template.guidance).fixedSize(horizontal: false, vertical: true)
                        }
                        Text("Built-in templates can't be edited. Add your own with +.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        TextField("Name", text: $draft.name)
                        LabeledContent("Sections") {
                            TextEditor(text: $draft.sections)
                                .font(.body)
                                .frame(height: 90)
                        }
                        LabeledContent("Guidance") {
                            TextEditor(text: $draft.guidance)
                                .font(.body)
                                .frame(height: 70)
                        }
                        HStack {
                            Text("One section per line. Guidance tells the model what matters most.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Save", action: save)
                                .disabled(draft.name.trimmed.isEmpty || draft == Draft(template))
                        }
                    }
                } else {
                    Text("Select a template").foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 520, height: 340)
        .task { library.reload() }
        .onChange(of: selection) { _, _ in
            if let template = selectedCustom { draft = Draft(template) }
        }
    }

    private var selectedTemplate: NoteTemplate? {
        library.templates.first { $0.id == selection }
    }

    private var selectedCustom: NoteTemplate? {
        selectedTemplate.flatMap { $0.isBuiltIn ? nil : $0 }
    }

    private func add() {
        let template = NoteTemplate(
            id: "custom-\(UUID().uuidString.prefix(8).lowercased())",
            name: "New template",
            sections: ["Discussion", "Decisions", "Action items"],
            guidance: "Capture what was decided and what happens next.")
        library.saveCustomTemplates(library.customTemplates + [template])
        selection = template.id
        draft = Draft(template)
    }

    private func save() {
        guard let original = selectedCustom else { return }
        let sections = draft.sections
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let updated = NoteTemplate(
            id: original.id, name: draft.name.trimmed,
            sections: sections.isEmpty ? ["Notes"] : sections,
            guidance: draft.guidance.trimmed)
        library.saveCustomTemplates(
            library.customTemplates.map { $0.id == original.id ? updated : $0 })
    }

    private func deleteSelected() {
        guard let template = selectedCustom else { return }
        library.saveCustomTemplates(library.customTemplates.filter { $0.id != template.id })
        selection = nil
    }
}

extension TemplatesSettings.Draft {
    fileprivate init(_ template: NoteTemplate) {
        self.init(
            name: template.name,
            sections: template.sections.joined(separator: "\n"),
            guidance: template.guidance)
    }
}
