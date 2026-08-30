import Foundation

let voxOSRefineXPCServiceName = "com.achyuthkp.VoxOS.RefineXPC"
let voxOSRefineXPCErrorDomain = "com.achyuthkp.VoxOS.RefineXPC"

struct VoxOSRefinePrepareRequest: Codable, Sendable {
    let requestID: UUID
    let modelDirectoryPath: String
    let systemPrompt: String
}

struct VoxOSRefineEnhanceRequest: Codable, Sendable {
    let requestID: UUID
    let modelDirectoryPath: String
    let systemPrompt: String
    let transcript: String
}

struct VoxOSRefineEnhanceResponse: Codable, Sendable {
    let requestID: UUID
    let output: String
}

enum VoxOSRefineXPCErrorCode: Int {
    case invalidRequest = 1
    case inferenceFailed = 2
    case invalidResponse = 3
    case connectionFailed = 4
}

@objc protocol VoxOSRefineXPCProtocol {
    func prepare(
        _ requestData: NSData,
        withReply reply: @escaping (NSError?) -> Void
    )

    func enhance(
        _ requestData: NSData,
        withReply reply: @escaping (NSData?, NSError?) -> Void
    )

    func shutdown(withReply reply: @escaping () -> Void)
}

func makeVoxOSRefineXPCError(
    _ code: VoxOSRefineXPCErrorCode,
    description: String
) -> NSError {
    NSError(
        domain: voxOSRefineXPCErrorDomain,
        code: code.rawValue,
        userInfo: [NSLocalizedDescriptionKey: description]
    )
}
