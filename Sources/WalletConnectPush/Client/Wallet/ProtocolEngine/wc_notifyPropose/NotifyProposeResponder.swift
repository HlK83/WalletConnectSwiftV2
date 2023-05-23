
import Foundation
import Combine

class NotifyProposeResponder {
    enum Errors: Error {
        case recordForIdNotFound
        case malformedRequestParams
    }
    private let networkingInteractor: NetworkInteracting
    private let kms: KeyManagementServiceProtocol
    private let logger: ConsoleLogging
    private let pushSubscribeRequester: PushSubscribeRequester
    private let rpcHistory: RPCHistory
    private var subscriptionResponsePublisher: AnyPublisher<Result<PushSubscription, Error>, Never>

    private var publishers = [AnyCancellable]()

    init(networkingInteractor: NetworkInteracting,
         kms: KeyManagementServiceProtocol,
         logger: ConsoleLogging,
         pushSubscribeRequester: PushSubscribeRequester,
         rpcHistory: RPCHistory,
        pushSubscribeResponseSubscriber: PushSubscribeResponseSubscriber
    ) {
        self.networkingInteractor = networkingInteractor
        self.kms = kms
        self.logger = logger
        self.pushSubscribeRequester = pushSubscribeRequester
        self.subscriptionResponsePublisher = pushSubscribeResponseSubscriber.subscriptionPublisher
        self.rpcHistory = rpcHistory
    }

    func approve(requestId: RPCID, onSign: @escaping SigningCallback) async throws {

        logger.debug("NotifyProposeResponder: approving proposal")

        guard let requestRecord = rpcHistory.get(recordId: requestId) else { throw Errors.recordForIdNotFound }
        let proposal = try requestRecord.request.params!.get(NotifyProposeParams.self)

        let subscriptionAuthWrapper = try await pushSubscribeRequester.subscribe(metadata: proposal.metadata, account: proposal.account, onSign: onSign)

        try await withCheckedThrowingContinuation { continuation in
            subscriptionResponsePublisher
                .first()
                .sink(receiveValue: { value in
                switch value {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }).store(in: &publishers)
        }

        guard let peerPublicKey = try? AgreementPublicKey(hex: proposal.publicKey) else {
            throw Errors.malformedRequestParams
        }

        let responseTopic = peerPublicKey.rawRepresentation.sha256().toHexString()

        let keys = try generateAgreementKeys(peerPublicKey: peerPublicKey)

        try kms.setSymmetricKey(keys.sharedKey, for: responseTopic)

        let response = RPCResponse(id: requestId, result: subscriptionAuthWrapper)

        let protocolMethod = NotifyProposeProtocolMethod()

        logger.debug("NotifyProposeResponder: sending response")

        try await networkingInteractor.respond(topic: responseTopic, response: response, protocolMethod: protocolMethod, envelopeType: .type1(pubKey: keys.publicKey.rawRepresentation))
        kms.deleteSymmetricKey(for: responseTopic)
    }

    private func generateAgreementKeys(peerPublicKey: AgreementPublicKey) throws -> AgreementKeys {
        let selfPubKey = try kms.createX25519KeyPair()
        let keys = try kms.performKeyAgreement(selfPublicKey: selfPubKey, peerPublicKey: peerPublicKey.hexRepresentation)
        return keys
    }
}
