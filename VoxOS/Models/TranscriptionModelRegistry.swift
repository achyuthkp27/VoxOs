import Foundation

enum TranscriptionModelRegistry {

    static var models: [any TranscriptionModel] {
        return predefinedModels + CustomCloudModelManager.shared.customModels
    }

    private static let predefinedModels: [any TranscriptionModel] = {
        let nonCloudModels: [any TranscriptionModel] = [
            // Native Apple Model
            NativeAppleModel(
                name: "apple-speech",
                displayName: "Apple Speech",
                description: "Uses the native Apple Speech framework for transcription. Requires macOS 26",
                isMultilingualModel: true,
                supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .nativeApple)
            ),

            // Parakeet Models
            FluidAudioModel(
                name: "parakeet-ultra-0.6b",
                displayName: "Parakeet Ultra",
                description: "Most accurate Parakeet: English and 24 other European languages",
                size: "630 MB",
                speed: 0.99,
                accuracy: 0.96,
                ramUsage: 0.9,
                supportsStreaming: true,
                supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .fluidAudio)
            ),
            FluidAudioModel(
                name: "parakeet-unified-0.6b",
                displayName: "Parakeet Unified",
                description: "English-only Parakeet model with native realtime transcription support",
                size: "1.2 GB",
                speed: 0.99,
                accuracy: 0.95,
                ramUsage: 1.0,
                supportsStreaming: true,
                supportedLanguages: LanguageDictionary.forProvider(isMultilingual: false, provider: .fluidAudio)
            ),

            TranscribeCppModel(
                name: "cohere-transcribe",
                displayName: "Cohere Transcribe",
                description: "Accurate multilingual transcription that runs privately on your Mac",
                size: "1.56 GB",
                speed: 0.75,
                accuracy: 0.95,
                ramUsage: 2.5,
                publisher: "Cohere",
                supportedLanguages: LanguageDictionary.cohereTranscribe
            ),
        ]

        let cloudModels: [any TranscriptionModel] = CloudProviderRegistry.allProviders.flatMap { $0.models }
        return nonCloudModels + cloudModels
    }()
}
