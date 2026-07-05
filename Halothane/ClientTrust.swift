import Foundation
import Security

/// Validates which processes may command the root daemon. The daemon can pause
/// and kill anything, so only our own signed UI may connect.
///
/// We pin the caller to Halothane's bundle identifier, an Apple anchor, and our
/// signing **team** (the cert's OU = Team ID). Pinning to the team rather than a
/// specific leaf cert means it keeps working across cert renewals and across
/// both Apple Development (debug) and Developer ID (release) builds from the same
/// team. `SecCodeCheckValidity` verifies the live process, not just a path, so
/// it isn't defeated by swapping a file on disk.
///
/// `teamOU` is the SFOLN LLC Team ID. Both the current Apple Development cert
/// and the future Developer ID Application/Installer certs carry this same OU,
/// so this pin holds across debug and release builds and across cert renewals —
/// no change needed when moving to Developer ID + notarization.
enum ClientTrust {

    /// Team ID (cert subject OU) that signs Halothane builds — SFOLN LLC.
    private static let teamOU = "MXBM8H7F26"

    /// Halothane's designated requirement (verify with `codesign -d -r-`).
    private static let requirementString =
        #"identifier "com.sfoln.Halothane" and anchor apple generic and certificate leaf[subject.OU] = ""# + teamOU + #"""#

    static func isAuthorized(_ conn: NSXPCConnection) -> Bool {
        let pid = conn.processIdentifier
        guard pid > 0 else { return false }

        var code: SecCode?
        let attrs = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess,
              let code else { return false }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementString as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }

        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}
