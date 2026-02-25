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
}
