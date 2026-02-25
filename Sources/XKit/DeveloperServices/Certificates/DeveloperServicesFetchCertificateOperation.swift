//
//  DeveloperServicesFetchCertificateOperation.swift
//  XKit
//
//  Created by Kabir Oberai on 13/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import DeveloperAPI
import Dependencies
#if canImport(Security)
import Security
#endif

public typealias DeveloperServicesCertificate = Components.Schemas.Certificate

public struct DeveloperServicesFetchCertificateOperation: DeveloperServicesOperation {

    public enum Error: LocalizedError {
        case csrFailed
        case userCancelled
        case certificateAlreadyExists(String?)
        case existingDevelopmentCertificateRequiresPrivateKey

        public var errorDescription: String? {
            switch self {
            case .csrFailed:
                return NSLocalizedString(
                    "fetch_certificate_operation.error.csr_failed", value: "CSR request failed", comment: ""
                )
            case .userCancelled:
                return NSLocalizedString(
                    "fetch_certificate_operation.error.user_cancelled", value: "The operation was cancelled", comment: ""
                )
            case .certificateAlreadyExists(let detail):
                if let detail, !detail.isEmpty {
                    return detail
                }
                return "A valid Development certificate already exists for this team."
            case .existingDevelopmentCertificateRequiresPrivateKey:
                return "A Development certificate already exists, but its private key is not available on this Mac."
            }
        }
    }

    @Dependency(\.signingInfoManager) var signingInfoManager

    public let context: SigningContext
    public let confirmRevocation: @Sendable ([DeveloperServicesCertificate]) async -> Bool
    public init(
        context: SigningContext,
        confirmRevocation: @escaping @Sendable ([DeveloperServicesCertificate]) async -> Bool
    ) {
        self.context = context
        self.confirmRevocation = confirmRevocation
    }

    private func createCertificate() async throws -> SigningInfo {
        let keypair = try Keypair()
        let csr = try keypair.generateCSR()
        let privateKey = try keypair.privateKey()

        let response = try await context.developerAPIClient.certificatesCreateInstance(
            body: .json(.init(data: .init(
                _type: .certificates,
                attributes: .init(
                    csrContent: csr.pemString,
                    certificateType: .init(.development)
                )
            )))
        )

        if let created = try? response.created,
           let jsonBody = try? created.body.json,
           let contentString = jsonBody.data.attributes?.certificateContent,
           let contentData = Data(base64Encoded: contentString) {
            let certificate = try Certificate(data: contentData)
            return SigningInfo(privateKey: privateKey, certificate: certificate)
        }

        if let conflict = try? response.conflict {
            throw Error.certificateAlreadyExists(conflictDetail(conflict))
        }

        throw Error.csrFailed
    }

    private func replaceCertificates(
        _ certificates: [DeveloperServicesCertificate],
        requireConfirmation: Bool
    ) async throws -> SigningInfo {
        if try await context.auth.team()?.isFree == true {
            if !certificates.isEmpty, requireConfirmation {
                guard await confirmRevocation(certificates)
                    else { throw CancellationError() }
            }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for certificate in certificates {
                    group.addTask {
                        _ = try await context.developerAPIClient
                            .certificatesDeleteInstance(path: .init(id: certificate.id))
                            .noContent
                    }
                }
                try await group.waitForAll()
            }
        }
        do {
            let signingInfo = try await createCertificate()
            persistSigningInfo(signingInfo)
            return signingInfo
        } catch Error.certificateAlreadyExists {
            let latestCertificates = try await context.developerAPIClient.certificatesGetCollection().ok.body.json.data
            if let recovered = loadSigningInfoFromKeychain(matching: latestCertificates) {
                persistSigningInfo(recovered)
                return recovered
            }
            throw Error.existingDevelopmentCertificateRequiresPrivateKey
        }
    }

    public func perform() async throws -> SigningInfo {
        let certificates = try await context.developerAPIClient.certificatesGetCollection().ok.body.json.data

        if let signingInfo = signingInfoManager[self.context.auth.identityID] {
            let knownSerialNumber = normalizeSerial(signingInfo.certificate.serialNumber())
            if let certificate = certificates.first(where: { certificate in
                normalizeSerial(certificate.attributes?.serialNumber ?? "") == knownSerialNumber
            }), isCertificateActive(certificate) {
                return signingInfo
            }
        }

        if let recovered = loadSigningInfoFromKeychain(matching: certificates) {
            persistSigningInfo(recovered)
            return recovered
        }

        let activeDevelopmentCertificates = certificates.filter { certificate in
            isDevelopmentCertificate(certificate) && isCertificateActive(certificate)
        }
        if !activeDevelopmentCertificates.isEmpty {
            throw Error.existingDevelopmentCertificateRequiresPrivateKey
        }

        // No reusable active Development cert exists, so create a new one.
        return try await self.replaceCertificates(certificates, requireConfirmation: true)
    }

    private func persistSigningInfo(_ signingInfo: SigningInfo) {
        signingInfoManager[self.context.auth.identityID] = signingInfo
        if let teamID = try? signingInfo.certificate.teamID(),
           !teamID.isEmpty,
           teamID != self.context.auth.identityID {
            signingInfoManager[teamID] = signingInfo
        }
    }

    private func normalizeSerial(_ serial: String) -> String {
        let trimmed = serial.uppercased().drop { $0 == "0" }
        return trimmed.isEmpty ? "0" : String(trimmed)
    }

    private func isCertificateActive(_ certificate: DeveloperServicesCertificate) -> Bool {
        guard let expirationDate = certificate.attributes?.expirationDate else {
            return true
        }
        return expirationDate > Date()
    }

    private func isDevelopmentCertificate(_ certificate: DeveloperServicesCertificate) -> Bool {
        let rawType = certificate.attributes?.certificateType?.value1?.rawValue
            ?? certificate.attributes?.certificateType?.value2
            ?? ""
        return rawType.uppercased().contains("DEVELOPMENT")
    }

    private func conflictDetail(
        _ conflict: Operations.CertificatesCreateInstance.Output.Conflict
    ) -> String? {
        guard let body = try? conflict.body.json else {
            return nil
        }
        let details = (body.errors ?? []).map(\.detail).filter { !$0.isEmpty }
        return details.isEmpty ? nil : details.joined(separator: " ")
    }

    private func loadSigningInfoFromKeychain(
        matching certificates: [DeveloperServicesCertificate]
    ) -> SigningInfo? {
        #if canImport(Security)
        let remoteSerials = Set(
            certificates
                .filter { isDevelopmentCertificate($0) && isCertificateActive($0) }
                .compactMap { $0.attributes?.serialNumber }
                .map(normalizeSerial)
        )
        guard !remoteSerials.isEmpty else {
            return nil
        }

        let query: [CFString: Any] = [
            kSecClass: kSecClassIdentity,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }

        let identities = result as? [SecIdentity] ?? []

        for identity in identities {
            guard let signingInfo = signingInfoFromIdentity(identity) else {
                continue
            }
            let serial = normalizeSerial(signingInfo.certificate.serialNumber())
            if remoteSerials.contains(serial) {
                return signingInfo
            }
        }

        return nil
        #else
        _ = certificates
        return nil
        #endif
    }

    #if canImport(Security)
    private func signingInfoFromIdentity(_ identity: SecIdentity) -> SigningInfo? {
        var certificateRef: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificateRef) == errSecSuccess,
              let certificateRef
        else {
            return nil
        }

        let certificateData = SecCertificateCopyData(certificateRef) as Data
        guard let certificate = try? Certificate(data: certificateData) else {
            return nil
        }

        var privateKeyRef: SecKey?
        guard SecIdentityCopyPrivateKey(identity, &privateKeyRef) == errSecSuccess,
              let privateKeyRef
        else {
            return nil
        }

        let attributes = SecKeyCopyAttributes(privateKeyRef) as NSDictionary?
        let keyType = attributes?[kSecAttrKeyType] as? String
        guard keyType == (kSecAttrKeyTypeRSA as String) else {
            return nil
        }

        var keyError: Unmanaged<CFError>?
        guard let rawPrivateKey = SecKeyCopyExternalRepresentation(privateKeyRef, &keyError) as Data? else {
            return nil
        }

        let privateKey = PrivateKey(data: pemEncodedRSAPrivateKey(rawPrivateKey))
        return SigningInfo(privateKey: privateKey, certificate: certificate)
    }

    private func pemEncodedRSAPrivateKey(_ keyData: Data) -> Data {
        let body = keyData.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        let pem = "-----BEGIN RSA PRIVATE KEY-----\n\(body)\n-----END RSA PRIVATE KEY-----\n"
        return Data(pem.utf8)
    }
    #endif

}
