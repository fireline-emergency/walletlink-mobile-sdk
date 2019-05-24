// Copyright (c) 2017-2019 Coinbase Inc. See LICENSE

import CBHTTP
import RxSwift

private typealias WalletLinkCallback = (requestId: Int32, subject: ReplaySubject<MessageResponse>)

private let sendTimeout: RxTimeInterval = 15

/// Represents a WalletLink WebSocket connection
final class WalletLinkWebSocket {
    private let disposeBag = DisposeBag()
    private let connection: WebSocket
    private var requestIdSequence = AtomicInt32()
    private var incomingHostEventsSubject = PublishSubject<MessageEvent>()
    private var pendingSignerRequests = BoundedCache<Int32, ReplaySubject<MessageResponse>>(maxSize: 300)
    private let pendingSignerRequestsAccessQueue = DispatchQueue(label: "pendingSignerRequestsAccessQueue")

    /// Incoming WalletLink host requests
    let incomingHostEventsObservable: Observable<MessageEvent>

    /// WalletLink Connection state
    let connectionStateObservable: Observable<WebConnectionState>

    /// Constructor
    ///
    /// - Parameters:
    ///     - url: WalletLink WebSocket URL
    required init(url: URL) {
        let connection = WebSocket(url: url)

        self.connection = connection
        incomingHostEventsObservable = incomingHostEventsSubject.asObservable()
        connectionStateObservable = connection.connectionStateObservable

        connection.incomingObservable
            .observeOn(ConcurrentDispatchQueueScheduler(qos: .userInitiated))
            .subscribe(onNext: { [weak self] in self?.handleIncomingType($0) })
            .disposed(by: disposeBag)
    }

    /// Connect to WalletLink server
    func connect() -> Single<Void> {
        return connection.connect()
    }

    /// Disconnect from WalletLink server
    func disconnect() -> Single<Void> {
        return connection.disconnect()
    }

    /// Join a WalletLink session
    ///
    /// - Parameters:
    ///   - sessionKey: sha256(session+secret) hash
    ///   - sessionId: session ID scanned offline (QR code, NFC, etc)
    ///
    /// - Returns: True if session is valid or false if invalid. An exception will be thrown if a network or connection
    ///            error occurs while in flight.
    func joinSession(using sessionKey: String, for sessionId: String) -> Single<Bool> {
        let callback = createCallback()
        let message = JoinSessionMessage(
            requestId: callback.requestId,
            sessionId: sessionId,
            sessionKey: sessionKey
        )

        return send(message, callback: callback)
    }

    /// Set metadata in the current session
    ///
    /// - Parameters:
    ///   - key: Metadata key on WalletLink server
    ///   - value: Metadata value stored on WalletLink server. This data may be encrypted.
    ///   - sessionId: Session ID scanned offline (QR code, NFC, etc)
    ///
    /// - Returns: True if the operation succeeds
    func setMetadata(key: ClientMetadataKey, value: String, for sessionId: String) -> Single<Bool> {
        let callback = createCallback()
        let message = SetMetadataMessage(
            requestId: callback.requestId,
            sessionId: sessionId,
            key: key.rawValue,
            value: value
        )

        return send(message, callback: callback)
    }

    /// Set session config once a link is established
    ///
    /// - Parameters:
    ///     - webhookId: Webhook ID used to push notifications to mobile client
    ///     - webhookUrl: Webhook URL used to push notifications to mobile client
    ///   - metadata: Metadata forwarded to host
    ///   - sessionId: Session ID scanned offline (QR code, NFC, etc)
    ///
    /// - Returns: True if the operation succeeds
    func setSessionConfig(
        webhookId: String,
        webhookUrl: URL,
        metadata: [String: String],
        for sessionId: String
    ) -> Single<Bool> {
        let callback = createCallback()
        let message = SetSessionConfigMessage(
            requestId: callback.requestId,
            sessionId: sessionId,
            webhookId: webhookId,
            webhookUrl: webhookUrl.absoluteString,
            metadata: metadata
        )

        return send(message, callback: callback)
    }

    /// Publish new event to WalletLink server
    ///
    /// - Parameters:
    ///   - event: Event name to publish
    ///   - data: the data associated with this event
    ///   - sessionId: Session ID scanned offline (QR code, NFC, etc)
    ///
    /// - Returns: Trie if the operation succeeds
    func publishEvent(_ event: String, data: [String: String], for sessionId: String) -> Single<Bool> {
        let callback = createCallback()
        let message = PublishEventMessage(
            requestId: callback.requestId,
            sessionId: sessionId,
            event: event,
            data: data
        )

        return send(message, callback: callback)
    }

    // MARK: - Send message helper(s)

    private func send(_ message: JSONSerializable, callback: WalletLinkCallback) -> Single<Bool> {
        guard let jsonString = message.asJSONString else {
            return .error(WalletLinkConnectionError.unableToSerializeMessageJSON)
        }

        return connection.sendString(jsonString)
            .flatMap { callback.subject.takeSingle() }
            .map { $0.type == .ok }
            .timeout(sendTimeout, scheduler: ConcurrentDispatchQueueScheduler(qos: .userInitiated))
            .logError()
            .catchError { err in
                self.deleteCallback(requestId: callback.requestId)
                throw err
            }
    }

    // MARK: - Pending requests callback management

    private func createCallback() -> WalletLinkCallback {
        let requestId = requestIdSequence.incrementAndGet()
        let subject = ReplaySubject<MessageResponse>.create(bufferSize: 1)

        pendingSignerRequestsAccessQueue.sync { self.pendingSignerRequests[requestId] = subject }

        return WalletLinkCallback(requestId: requestId, subject: subject)
    }

    private func deleteCallback(requestId: Int32) {
        pendingSignerRequestsAccessQueue.sync { self.pendingSignerRequests[requestId] = nil }
    }

    /// This is called when the host sends a response to a request initiated by the signer
    private func receivedMessageResponse(_ response: MessageResponse) {
        guard let requestId = response.requestId else {
            return assertionFailure("Invalid WalletLink message link response \(response)")
        }

        var subject: ReplaySubject<MessageResponse>?

        pendingSignerRequestsAccessQueue.sync {
            subject = self.pendingSignerRequests[requestId]
            self.pendingSignerRequests[requestId] = nil
        }

        subject?.onNext(response)
    }

    /// this is called when the host sends a request initiated by the host
    private func receivedMessageEvent(_ event: MessageEvent) {
        incomingHostEventsSubject.onNext(event)
    }

    private func handleIncomingType(_ incoming: WebIncomingDataType) {
        guard
            case let .text(jsonString) = incoming,
            let json = jsonString.jsonObject as? [String: Any],
            let typeString = json["type"] as? String,
            let type = ServerMessageType(rawValue: typeString)
        else {
            return assertionFailure("Unknown WalletLink type \(incoming)")
        }

        switch type {
        case .ok, .fail:
            guard let response = MessageResponse.fromJSONString(jsonString) else {
                return assertionFailure("[walletlink] Invalid message response \(jsonString)")
            }

            receivedMessageResponse(response)
        case .event:
            guard let event = MessageEvent.fromJSONString(jsonString) else {
                return assertionFailure("[walletlink] Invalid message event \(jsonString)")
            }

            receivedMessageEvent(event)
        }
    }
}

enum EventType: String {
    /// Web3 related requests
    case web3Request = "Web3Request"
}

/*
 {
 "type":"Event",
 "sessionId":"39750b194d6cdc126fc91875bc8e5b5a",
 "eventId":"03244a14",
 "event":"Web3Request",
 "data":"0d7743fa1e43df2c805a1a407073fee0bdb894863e13ad3a7f13ad6a670bdfcf74cdd1097191a850c9826feeea1bd30e6f2d60f1a2036ef17b2baef2a0a04a84e5378426a382a1714a45de230b3de6bcb378ba8311e7c6d4f18ea9be9b326d39699a4ba184f081338d2b75c0f24216c83b985e2531b551ae9b8db8304edc5a85dfed2aedc844e502443013d967257174f04d0ee3a2d11ba0d69936b9615e3c08eb1781ae25d9c7e77d"
 }
*/