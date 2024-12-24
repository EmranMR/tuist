import Foundation
import TuistCore
import XcodeGraph
import ServiceContextModule

/// Mapper that generates a new scheme `ProjectName-Workspace` that includes all targets from a given workspace
public final class AutogeneratedWorkspaceSchemeWorkspaceMapper: WorkspaceMapping { // swiftlint:disable:this type_name
    let forceWorkspaceSchemes: Bool

    // MARK: - Init

    public init(forceWorkspaceSchemes: Bool) {
        self.forceWorkspaceSchemes = forceWorkspaceSchemes
    }

    public func map(workspace: WorkspaceWithProjects) throws -> (WorkspaceWithProjects, [SideEffectDescriptor]) {
        guard workspace.workspace.generationOptions.autogeneratedWorkspaceSchemes != .disabled || forceWorkspaceSchemes,
              let project = workspace.projects.first
        else {
            return (workspace, [])
        }
        ServiceContext.current?.logger?.debug("Transforming workspace \(workspace.workspace.name): Auto-generating workspace scheme")

        let platforms = Set(
            workspace.projects
                .flatMap {
                    $0.targets.values.flatMap(\.supportedPlatforms)
                }
        )

        let schemes: [Scheme]

        schemes = [
            scheme(
                name: "\(workspace.workspace.name)-Workspace",
                platforms: platforms,
                project: project,
                workspace: workspace
            ),
        ]

        var workspace = workspace
        workspace.workspace.schemes.append(contentsOf: schemes)
        return (workspace, [])
    }

    // MARK: - Helpers

    private func scheme(
        name: String,
        platforms: Set<Platform>,
        project: Project,
        workspace: WorkspaceWithProjects
    ) -> Scheme {
        let testingOptions = workspace.workspace.generationOptions.autogeneratedWorkspaceSchemes.testingOptions
        var (targets, testableTargets): ([TargetReference], [TestableTarget]) = workspace.projects
            .reduce(([], [])) { result, project in
                let targets = project.targets
                    .values
                    .filter { !$0.supportedPlatforms.isDisjoint(with: platforms) }
                    .map { TargetReference(projectPath: project.path, name: $0.name) }
                let testableTargets = project.targets
                    .values
                    .filter { !$0.supportedPlatforms.isDisjoint(with: platforms) }
                    .filter(\.product.testsBundle)
                    .map { TargetReference(projectPath: project.path, name: $0.name) }
                    .map {
                        TestableTarget(
                            target: $0,
                            parallelizable: testingOptions.contains(.parallelizable),
                            randomExecutionOrdering: testingOptions.contains(.randomExecutionOrdering)
                        )
                    }

                return (result.0 + targets, result.1 + testableTargets)
            }

        targets = targets.sorted(by: { $0.name < $1.name })
        testableTargets = testableTargets.sorted(by: { $0.target.name < $1.target.name })

        let coverageSettings = codeCoverageSettings(workspace: workspace)

        return Scheme(
            name: name,
            shared: true,
            buildAction: BuildAction(targets: targets),
            testAction: TestAction(
                targets: testableTargets,
                arguments: nil,
                configurationName: project.defaultDebugBuildConfigurationName,
                attachDebugger: true,
                coverage: coverageSettings.isEnabled,
                codeCoverageTargets: coverageSettings.targets,
                expandVariableFromTarget: nil,
                preActions: [],
                postActions: [],
                diagnosticsOptions: SchemeDiagnosticsOptions(
                    mainThreadCheckerEnabled: true,
                    performanceAntipatternCheckerEnabled: true
                ),
                language: workspace.workspace.generationOptions.autogeneratedWorkspaceSchemes.testLanguage,
                region: workspace.workspace.generationOptions.autogeneratedWorkspaceSchemes.testRegion,
                preferredScreenCaptureFormat: workspace.workspace.generationOptions.autogeneratedWorkspaceSchemes
                    .testScreenCaptureFormat
            )
        )
    }

    private func codeCoverageSettings(workspace: WorkspaceWithProjects) -> (isEnabled: Bool, targets: [TargetReference]) {
        let codeCoverageTargets = workspace.workspace.codeCoverageTargets(projects: workspace.projects)

        switch workspace.workspace.generationOptions.autogeneratedWorkspaceSchemes.codeCoverageMode {
        case .all: return (true, codeCoverageTargets)
        case .disabled: return (false, codeCoverageTargets)
        case .targets: return (true, codeCoverageTargets)
        case .relevant:
            return (!codeCoverageTargets.isEmpty, codeCoverageTargets)
        }
    }
}
