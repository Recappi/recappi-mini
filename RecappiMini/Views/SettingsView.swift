import SwiftUI

struct SettingsView: View {
    @ObservedObject private var config = AppConfig.shared
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Settings")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(IconButtonStyle())
            }

            Divider()

            // Speech language (for local ASR)
            HStack {
                Text("Language")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $config.speechLanguage) {
                    Text("English").tag("en-US")
                    Text("中文").tag("zh-CN")
                    Text("日本語").tag("ja-JP")
                }
                .pickerStyle(.menu)
                .frame(width: 100)
            }

            // LLM provider (for summary, or override transcription)
            HStack {
                Text("LLM")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $config.llmProvider) {
                    ForEach(LLMProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 100)
            }

            // API key input
            if config.selectedProvider.needsApiKey {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(config.selectedProvider.displayName) API Key")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        SecureField("Enter API key...", text: apiKeyBinding)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Summary prompt")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if !isDefaultPrompt {
                            Button("Reset") { config.summaryPrompt = AppConfig.defaultSummaryPrompt }
                                .buttonStyle(.borderless)
                                .font(.system(size: 10))
                                .foregroundStyle(.blue)
                        }
                    }
                    TextEditor(text: $config.summaryPrompt)
                        .font(.system(size: 10))
                        .frame(height: 90)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 5))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(.separator, lineWidth: 0.5)
                        )
                }
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    private var isDefaultPrompt: Bool {
        config.summaryPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            == AppConfig.defaultSummaryPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var apiKeyBinding: Binding<String> {
        switch config.selectedProvider {
        case .gemini:
            return Binding(get: { config.geminiApiKey }, set: { config.setGeminiApiKey($0) })
        case .openai:
            return Binding(get: { config.openaiApiKey }, set: { config.setOpenaiApiKey($0) })
        case .none:
            return .constant("")
        }
    }
}
