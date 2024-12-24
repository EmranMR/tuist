import Foundation
import Path
import TuistLoader
import TuistServer
import TuistSupport
import ServiceContextModule

protocol OrganizationUpdateSSOServicing {
    func run(
        organizationName: String,
        provider: SSOProvider,
        organizationId: String,
        directory: String?
    ) async throws
}

final class OrganizationUpdateSSOService: OrganizationUpdateSSOServicing {
    private let updateOrganizationService: UpdateOrganizationServicing
    private let serverURLService: ServerURLServicing
    private let configLoader: ConfigLoading

    init(
        updateOrganizationService: UpdateOrganizationServicing = UpdateOrganizationService(),
        serverURLService: ServerURLServicing = ServerURLService(),
        configLoader: ConfigLoading = ConfigLoader(warningController: WarningController.shared)
    ) {
        self.updateOrganizationService = updateOrganizationService
        self.serverURLService = serverURLService
        self.configLoader = configLoader
    }

    func run(
        organizationName: String,
        provider: SSOProvider,
        organizationId: String,
        directory: String?
    ) async throws {
        let directoryPath: AbsolutePath
        if let directory {
            directoryPath = try AbsolutePath(validating: directory, relativeTo: FileHandler.shared.currentPath)
        } else {
            directoryPath = FileHandler.shared.currentPath
        }
        let config = try await configLoader.loadConfig(path: directoryPath)

        let ssoOrganization: SSOOrganization
        switch provider {
        case .google:
            ssoOrganization = .google(organizationId)
        case .okta:
            ssoOrganization = .okta(organizationId)
        }

        let serverURL = try serverURLService.url(configServerURL: config.url)
        _ = try await updateOrganizationService.updateOrganization(
            organizationName: organizationName,
            serverURL: serverURL,
            ssoOrganization: ssoOrganization
        )

        ServiceContext.$current.get()?.logger?
            .info(
                "\(organizationName) now uses \(provider.rawValue.capitalized) SSO with \(organizationId). Users authenticated with the \(organizationId) SSO organization will automatically have access to the \(organizationName) projects."
            )
    }
}
