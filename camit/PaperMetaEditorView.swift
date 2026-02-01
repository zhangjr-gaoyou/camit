import SwiftUI

struct PaperMetaEditorView: View {
    let item: ScanItem
    let onSave: (String, Grade, Subject, Int?) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var grade: Grade
    @State private var subject: Subject
    @State private var scoreText: String

    init(item: ScanItem, onSave: @escaping (String, Grade, Subject, Int?) -> Void) {
        self.item = item
        self.onSave = onSave
        _title = State(initialValue: item.title)
        _grade = State(initialValue: item.grade)
        _subject = State(initialValue: item.subject)
        if let score = item.score {
            _scoreText = State(initialValue: "\(score)")
        } else {
            _scoreText = State(initialValue: "")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.paperMetaSection) {
                    TextField(L10n.paperMetaName, text: $title)

                    Picker(L10n.paperMetaGrade, selection: $grade) {
                        ForEach(Grade.allCases, id: \.self) { g in
                            Text(g.displayName).tag(g)
                        }
                    }

                    Picker(L10n.paperMetaSubject, selection: $subject) {
                        ForEach(Subject.allCases, id: \.self) { s in
                            Text(s.displayName).tag(s)
                        }
                    }

                    TextField(L10n.paperMetaScore, text: $scoreText)
                        .keyboardType(.numberPad)
                }
            }
            .navigationTitle(L10n.paperMetaTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.paperMetaSave, action: save)
                }
            }
        }
    }

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let score: Int?
        if let value = Int(scoreText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            score = value
        } else {
            score = nil
        }
        onSave(trimmedTitle.isEmpty ? item.title : trimmedTitle, grade, subject, score)
        dismiss()
    }
}

#Preview {
    let sample = ScanItem(
        title: "代数小测 #4",
        createdAt: .now,
        grade: .primary5,
        subject: .math,
        imageFileNames: []
    )
    PaperMetaEditorView(item: sample) { _, _, _, _ in }
}

