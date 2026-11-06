import Foundation
import Testing
@testable import PaseoKit

@Test func companionRetriesTransportLossesButNotRejectedRequests() {
    #expect(HostStore.isConnectionLoss(DaemonConnectionError.closed("Software caused connection abort")))
    #expect(HostStore.isConnectionLoss(NSError(domain: NSPOSIXErrorDomain, code: 53)))
    #expect(HostStore.isConnectionLoss(URLError(.networkConnectionLost)))
    #expect(HostStore.isConnectionLoss(HostStore.ActionError.notConnected))
    #expect(!HostStore.isConnectionLoss(DaemonConnectionError.rpc(requestType: "schedule/list", code: "unsupported", message: "Not supported")))
    #expect(!HostStore.isConnectionLoss(DaemonConnectionError.rejected(reason: "incorrect_password")))
    #expect(!HostStore.isConnectionLoss(DaemonConnectionError.timeout("schedule/list")))
    #expect(!HostStore.isConnectionLoss(CancellationError()))
}
