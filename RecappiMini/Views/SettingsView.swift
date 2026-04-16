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
                .buttonStyle(.plain)
            }

            Divider()

            // LLM provider (used for transcription + summary)
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
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    private var apiKeyBinding: Binding<String> {
        switch config.selectedProvider {
        case .gemini: return $config.geminiApiKey
        case .openai: return $config.openaiApiKey
        case .none: return .constant("")
        }
    }
}
