import AVFoundation

/// Plain words for what iOS reports as error codes ("OSStatus error 561015905").
enum Explain {
    static func audio(_ error: Error) -> String {
        switch AVAudioSession.ErrorCode(rawValue: (error as NSError).code) {
        case .isBusy, .cannotInterruptOthers, .insufficientPriority:
            return "Another app is using the audio (a call, Siri or a music app). Stop it there, then try again."
        case .siriIsRecording:
            return "Siri is listening. Try again when it's done."
        case .mediaServicesFailed:
            return "The iPhone's audio restarted. Try again."
        default:
            return "iOS didn't let the audio start just now. Try again; if it keeps happening, close the app and open it again."
        }
    }

    static func isNetwork(_ error: Error) -> Bool {
        (error as NSError).domain == NSURLErrorDomain
    }

    /// For a failed download or upload.
    static func network(_ error: Error) -> String {
        guard let url = error as? URLError else { return error.localizedDescription }
        switch url.code {
        case .notConnectedToInternet, .dataNotAllowed:
            return "The iPhone is offline."
        case .networkConnectionLost, .timedOut:
            return "The connection to Nextcloud dropped."
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return "Nextcloud can't be reached."
        default:
            return "The connection to Nextcloud failed."
        }
    }

    static func camera(_ error: Error) -> String {
        "The camera couldn't start (another app may be using it). Switch video off and on to try again."
    }
}
