//
//  ContentView.swift
//  camit
//
//  Created by zhang jia rong on 2026/1/27.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var settings = AppSettings()

    @State private var inputText: String = ""
    @State private var outputText: String = ""
    @State private var isSending: Bool = false

    @State private var isShowingSettings: Bool = false
    @State private var alertMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                ScrollView {
                    Text(outputText.isEmpty ? "回复将显示在这里。" : outputText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                TextEditor(text: $inputText)
                    .frame(minHeight: 120, maxHeight: 220)
                    .padding(8)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                HStack {
                    Spacer()
                    Button {
                        Task { await send() }
                    } label: {
                        if isSending {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("发送")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSending || inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding()
            .navigationTitle("camit")
            .toolbar {
#if os(macOS)
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isShowingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .help("设置")
                }
#else
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
#endif
            }
            .sheet(isPresented: $isShowingSettings) {
                SettingsView(settings: settings)
            }
            .alert("提示", isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(alertMessage ?? "")
            }
        }
    }

    @MainActor
    private func send() async {
        let prompt = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }

        let config = settings.bailianConfig
        guard !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            alertMessage = "请先在设置里填写 API Key。"
            isShowingSettings = true
            return
        }
        guard !config.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            alertMessage = "请先在设置里填写模型名称。"
            isShowingSettings = true
            return
        }

        isSending = true
        defer { isSending = false }

        do {
            let reply = try await BailianClient().chat(prompt: prompt, config: config)
            outputText = reply
        } catch {
            alertMessage = error.localizedDescription
        }
    }
}

#Preview {
    ContentView()
}
