import SwiftUI

@MainActor
final class OllamaSetupModel: ObservableObject {
    enum ConnectionState: Equatable {
        case unknown
        case testing
        case connected(version: String?)
        case failed(String)
    }

    struct PullState: Equatable {
        let model: String
        var status: String
        var fraction: Double?
    }

    @Published var serverAddress: String
    @Published private(set) var connection: ConnectionState = .unknown
    @Published private(set) var models: [OllamaInstalledModel] = []
    @Published private(set) var isLoadingModels = false
    @Published private(set) var listError: String?
    @Published var pullName = ""
    @Published private(set) var pull: PullState?
    @Published private(set) var pullError: String?
    @Published private(set) var deletingModel: String?
    @Published var actionError: String?

    private var pullTask: Task<Void, Never>?

    init() {
        serverAddress =
            UserDefaults.standard.string(forKey: DefaultsKeys.ollamaBaseURL) ?? OllamaService.defaultBaseURL
    }

    private var client: OllamaManagementClient? {
        OllamaManagement.normalizedBaseURL(serverAddress).map(OllamaManagementClient.init(baseURL:))
    }

    /// Saves the normalised address; returns false when it cannot be parsed.
    func saveAddress(to aiService: AIService) -> Bool {
        guard let url = OllamaManagement.normalizedBaseURL(serverAddress) else {
            connection = .failed(String(localized: "Invalid Ollama server URL"))
            return false
        }
        serverAddress = url.absoluteString
        aiService.updateOllamaBaseURL(url.absoluteString)
        return true
    }

    func testConnection() async {
        guard let client else {
            connection = .failed(String(localized: "Invalid Ollama server URL"))
            return
        }
        connection = .testing
        do {
            let installed = try await client.installedModels()
            // The version is a nice-to-have; an older server without /api/version is still usable.
            let version = try? await client.version()
            models = installed
            listError = nil
            connection = .connected(version: version)
        } catch {
            connection = .failed(error.localizedDescription)
        }
    }

    func reloadModels() async {
        guard let client else {
            listError = String(localized: "Invalid Ollama server URL")
            return
        }
        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            models = try await client.installedModels()
            listError = nil
        } catch {
            listError = error.localizedDescription
        }
    }

    func startPull(onFinish: @escaping @MainActor () async -> Void) {
        guard pull == nil, let client else { return }
        guard let name = OllamaManagement.normalizedModelName(pullName) else {
            pullError = String(localized: "Enter a model name such as llama3.2 or qwen3:8b.")
            return
        }
        pullError = nil
        pull = PullState(model: name, status: String(localized: "Starting…"), fraction: nil)

        pullTask = Task { [weak self] in
            do {
                try await client.pull(model: name) { [weak self] progress in
                    await self?.apply(progress)
                }
                self?.pullName = ""
            } catch is CancellationError {
                // User cancelled; nothing to report.
            } catch let error as URLError where error.code == .cancelled {
                // URLSession surfaces task cancellation this way while reading the stream.
            } catch {
                self?.pullError = error.localizedDescription
            }
            self?.pull = nil
            self?.pullTask = nil
            await self?.reloadModels()
            await onFinish()
        }
    }

    func cancelPull() {
        pullTask?.cancel()
    }

    private func apply(_ progress: OllamaPullProgress) {
        guard var current = pull else { return }
        let fraction = progress.fraction
        // Lines arrive many times per second; skip ones that would not visibly change the bar.
        if current.status == progress.status, let old = current.fraction, let new = fraction, abs(new - old) < 0.005 {
            return
        }
        current.status = progress.status
        current.fraction = fraction
        pull = current
    }

    func delete(_ model: OllamaInstalledModel) async -> Bool {
        guard let client else { return false }
        deletingModel = model.name
        defer { deletingModel = nil }
        do {
            try await client.delete(model: model.name)
            await reloadModels()
            return true
        } catch {
            actionError = error.localizedDescription
            return false
        }
    }
}

struct OllamaSetupView: View {
    @EnvironmentObject private var aiService: AIService
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = OllamaSetupModel()

    @State private var defaultModel =
        UserDefaults.standard.string(forKey: DefaultsKeys.ollamaSelectedModel) ?? ""
    @State private var modelPendingDeletion: OllamaInstalledModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    serverSection
                    modelsSection
                    pullSection
                }
                .padding(20)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560, height: 620)
        .task {
            await model.testConnection()
            let names = model.models.map(\.name)
            if !names.contains(defaultModel), let first = names.first {
                defaultModel = first
            }
        }
        .alert(
            "Delete \(modelPendingDeletion?.name ?? "")?",
            isPresented: Binding(
                get: { modelPendingDeletion != nil },
                set: { if !$0 { modelPendingDeletion = nil } }
            ),
            presenting: modelPendingDeletion
        ) { target in
            Button("Delete", role: .destructive) {
                Task { await delete(target) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { target in
            Text(
                "This removes the model files from this Mac and frees \(OllamaManagement.formattedSize(target.sizeBytes)). You can pull it again later."
            )
        }
        .alert(
            "Ollama",
            isPresented: Binding(
                get: { model.actionError != nil },
                set: { if !$0 { model.actionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionError ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Local LLM Setup")
                .font(.app(size: 14, weight: .semibold))
            Text("Ollama models used for AI enhancement and the Agent. Speech-to-text models are managed separately.")
                .font(.app(.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }

    // MARK: - Server

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Server")
            HStack(spacing: 8) {
                TextField("", text: $model.serverAddress, prompt: Text(verbatim: OllamaService.defaultBaseURL))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveAndTest)
                Button("Save & Test", action: saveAndTest)
                    .disabled(model.connection == .testing)
            }
            connectionStatus
        }
    }

    @ViewBuilder
    private var connectionStatus: some View {
        switch model.connection {
        case .unknown:
            EmptyView()
        case .testing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Testing connection…")
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
            }
        case .connected(let version):
            Label {
                if let version {
                    Text("Connected — Ollama \(version)")
                } else {
                    Text("Connected")
                }
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AppTheme.Status.success)
            }
            .font(.app(.caption))
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text(message)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "xmark.octagon.fill")
                }
                .foregroundStyle(AppTheme.Status.error)
                Text("Make sure Ollama is running (open the Ollama app or run `ollama serve`).")
                    .foregroundStyle(.secondary)
            }
            .font(.app(.caption))
        }
    }

    // MARK: - Installed models

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("Installed Models")
                Spacer()
                Button {
                    Task { await model.reloadModels() }
                } label: {
                    if model.isLoadingModels {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .controlSize(.small)
                .disabled(model.isLoadingModels)
            }

            if let error = model.listError {
                Text(error)
                    .font(.app(.caption))
                    .foregroundStyle(AppTheme.Status.error)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.models.isEmpty {
                Text("No models installed yet. Pull one below.")
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.models) { installed in
                        modelRow(installed)
                        if installed.id != model.models.last?.id {
                            Divider()
                        }
                    }
                }
                .background(AppMaterialCardBackground(cornerRadius: 9))

                HStack(spacing: 8) {
                    Text("Default model")
                        .font(.app(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Picker("Default model", selection: $defaultModel) {
                        ForEach(model.models) { installed in
                            Text(installed.name).tag(installed.name)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 280, alignment: .leading)
                    .onChange(of: defaultModel) { _, newValue in
                        guard !newValue.isEmpty else { return }
                        aiService.selectModel(newValue, for: .ollama)
                    }
                    InfoTip(
                        message:
                            "Used when Ollama is the AI provider for enhancement or the Agent. Cloud models send your text to Ollama's servers."
                    )
                }
                .padding(.top, 4)
            }
        }
    }

    private func modelRow(_ installed: OllamaInstalledModel) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(installed.name)
                        .font(.app(size: 13, weight: .medium))
                    if installed.name == defaultModel {
                        Text("Default")
                            .font(.app(.caption))
                            .foregroundStyle(.secondary)
                    }
                }
                if installed.isCloud {
                    Label("Cloud — runs on Ollama's servers, needs `ollama signin`", systemImage: "cloud")
                        .font(.app(.caption))
                        .foregroundStyle(AppTheme.Status.warning)
                } else {
                    Text(localDetail(installed))
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if model.deletingModel == installed.name {
                ProgressView().controlSize(.small)
            } else if !installed.isCloud {
                Button(role: .destructive) {
                    modelPendingDeletion = installed
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete \(installed.name)")
                .disabled(model.deletingModel != nil || model.pull != nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func localDetail(_ installed: OllamaInstalledModel) -> String {
        let size = OllamaManagement.formattedSize(installed.sizeBytes)
        guard let parameters = installed.parameterSize, !parameters.isEmpty else { return size }
        return "\(size) · \(parameters)"
    }

    // MARK: - Pull

    private var pullSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                sectionTitle("Pull a Model")
                InfoTip(
                    message:
                        "Downloads a model from the Ollama library, for example llama3.2, qwen3:8b or gemma3:4b. Names ending in -cloud or :cloud do not download weights; they run remotely."
                )
            }
            HStack(spacing: 8) {
                TextField("", text: $model.pullName, prompt: Text(verbatim: "llama3.2"))
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.pull != nil)
                    .onSubmit(startPull)
                if model.pull != nil {
                    Button("Cancel", action: model.cancelPull)
                } else {
                    Button("Pull", action: startPull)
                        .disabled(model.pullName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            if let pull = model.pull {
                VStack(alignment: .leading, spacing: 4) {
                    if let fraction = pull.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    HStack {
                        Text(pull.status)
                        Spacer()
                        if let fraction = pull.fraction {
                            Text(fraction, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit()
                        }
                    }
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
                }
            }

            if let error = model.pullError {
                Text(error)
                    .font(.app(.caption))
                    .foregroundStyle(AppTheme.Status.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Actions

    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.app(size: 13, weight: .semibold))
    }

    private func saveAndTest() {
        guard model.saveAddress(to: aiService) else { return }
        Task {
            await model.testConnection()
            await syncAppModels()
        }
    }

    private func startPull() {
        model.startPull { await syncAppModels() }
    }

    private func delete(_ target: OllamaInstalledModel) async {
        guard await model.delete(target) else { return }
        await syncAppModels()
    }

    /// Keeps AIService's cached model list (used by the provider pickers) in step with this screen,
    /// and moves the default off a model that no longer exists.
    private func syncAppModels() async {
        _ = await aiService.refreshOllamaAvailability()
        let names = model.models.map(\.name)
        if !names.contains(defaultModel), let first = names.first {
            defaultModel = first
        }
    }
}
