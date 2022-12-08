import Foundation
import WalletConnectNetworking

public class EchoClient {
    private let registerService: EchoRegisterService

    init(registerService: EchoRegisterService) {
        self.registerService = registerService
    }

    public func register(deviceToken: Data) async throws {
        try await registerService.register(deviceToken: deviceToken)
    }

}
