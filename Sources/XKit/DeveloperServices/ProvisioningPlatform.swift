import Foundation
import DeveloperAPI

public enum ProvisioningPlatform: Sendable {
    case iOS
    case macOS

    init(appBundleURL: URL) {
        let macInfoPlist = appBundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Info.plist")
        self = FileManager.default.fileExists(atPath: macInfoPlist.path) ? .macOS : .iOS
    }

    var bundleIDPlatform: Components.Schemas.BundleIdPlatform.Value1Payload {
        switch self {
        case .iOS:
            return .ios
        case .macOS:
            return .macOs
        }
    }

    var profileType: Components.Schemas.ProfileCreateRequest.DataPayload.AttributesPayload.ProfileTypePayload
        .Value1Payload {
        switch self {
        case .iOS:
            return .iosAppDevelopment
        case .macOS:
            return .macAppDevelopment
        }
    }

    var developerServicesPlatform: DeveloperServicesPlatform {
        switch self {
        case .iOS:
            return .iOS
        case .macOS:
            return .macOS
        }
    }

    var embeddedProvisioningProfileRelativePath: String {
        switch self {
        case .iOS:
            return "embedded.mobileprovision"
        case .macOS:
            return "Contents/embedded.provisionprofile"
        }
    }

    var displayName: String {
        switch self {
        case .iOS:
            return "iOS"
        case .macOS:
            return "macOS"
        }
    }

    func supports(
        devicePlatform: Components.Schemas.BundleIdPlatform.Value1Payload
    ) -> Bool {
        switch self {
        case .iOS:
            return devicePlatform == .ios || devicePlatform == .universal
        case .macOS:
            return devicePlatform == .macOs || devicePlatform == .universal
        }
    }

    func supports(
        deviceClass: Components.Schemas.Device.AttributesPayload.DeviceClassPayload.Value1Payload
    ) -> Bool {
        switch self {
        case .iOS:
            switch deviceClass {
            case .ipad, .iphone, .ipod:
                return true
            default:
                return false
            }
        case .macOS:
            return deviceClass == .mac
        }
    }

    /// Selects the record of the device with `udid`.
    ///
    /// Apple's device records do not always use the values of the API spec. For an
    /// Apple silicon Mac, Apple returns the platform "MACOS" and the device class
    /// "APPLE_SILICON_MAC". Thus the UDID selects the record. If Apple has more than
    /// one record for the UDID, the record for this platform is used.
    func deviceRecord(
        withUDID udid: String,
        in devices: [Components.Schemas.Device]
    ) -> Components.Schemas.Device? {
        let normalizedUDID = udid.uppercased()
        let matches = devices.filter { $0.attributes?.udid?.uppercased() == normalizedUDID }
        guard matches.count > 1 else {
            return matches.first
        }
        return matches.first { supports(recordPlatform: $0.attributes?.platform) } ?? matches.first
    }

    /// True when the platform of a device record is this platform or UNIVERSAL.
    /// Apple sends "MACOS" as well as the spec value "MAC_OS".
    func supports(recordPlatform: Components.Schemas.BundleIdPlatform?) -> Bool {
        guard let name = recordPlatform?.value2 ?? recordPlatform?.value1?.rawValue else {
            return false
        }
        let normalizedName = name.uppercased().replacingOccurrences(of: "_", with: "")
        switch self {
        case .iOS:
            return normalizedName == "IOS" || normalizedName == "UNIVERSAL"
        case .macOS:
            return normalizedName == "MACOS" || normalizedName == "UNIVERSAL"
        }
    }
}
