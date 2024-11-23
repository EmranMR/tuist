import FileSystem
import Foundation
import Path
import TuistCore
import TuistLoader
import TuistSupport
import XcodeGraph

protocol ProjectEditorMapping: AnyObject {
    func map(
        name: String,
        tuistPath: AbsolutePath,
        sourceRootPath: AbsolutePath,
        destinationDirectory: AbsolutePath,
        configPath: AbsolutePath?,
        packageManifestPath: AbsolutePath?,
        projectManifests: [AbsolutePath],
        editablePluginManifests: [EditablePluginManifest],
        pluginProjectDescriptionHelpersModule: [ProjectDescriptionHelpersModule],
        helpers: [AbsolutePath],
        templateSources: [AbsolutePath],
        templateResources: [AbsolutePath],
        resourceSynthesizers: [AbsolutePath],
        stencils: [AbsolutePath],
        projectDescriptionSearchPath: AbsolutePath
    ) async throws -> Graph
}

// swiftlint:disable:next type_body_length
final class ProjectEditorMapper: ProjectEditorMapping {
    private let swiftPackageManagerController: SwiftPackageManagerControlling
    private let fileSystem: FileSysteming

    init(
        swiftPackageManagerController: SwiftPackageManagerControlling = SwiftPackageManagerController(
            system: System.shared,
            fileSystem: FileSystem()
        ),
        fileSystem: FileSysteming = FileSystem()
    ) {
        self.swiftPackageManagerController = swiftPackageManagerController
        self.fileSystem = fileSystem
    }

    // swiftlint:disable:next function_body_length
    func map(
        name: String,
        tuistPath: AbsolutePath,
        sourceRootPath: AbsolutePath,
        destinationDirectory: AbsolutePath,
        configPath: AbsolutePath?,
        packageManifestPath: AbsolutePath?,
        projectManifests: [AbsolutePath],
        editablePluginManifests: [EditablePluginManifest],
        pluginProjectDescriptionHelpersModule: [ProjectDescriptionHelpersModule],
        helpers: [AbsolutePath],
        templateSources: [AbsolutePath],
        templateResources: [AbsolutePath],
        resourceSynthesizers: [AbsolutePath],
        stencils: [AbsolutePath],
        projectDescriptionSearchPath: AbsolutePath
    ) async throws -> Graph {
        logger.notice("Building the editable project graph")
        let swiftVersion = try SwiftVersionProvider.shared.swiftVersion()

        let pluginsProject = try await mapPluginsProject(
            pluginManifests: editablePluginManifests,
            projectDescriptionPath: projectDescriptionSearchPath,
            swiftVersion: swiftVersion,
            sourceRootPath: sourceRootPath,
            destinationDirectory: destinationDirectory,
            tuistPath: tuistPath
        )

        let manifestsProject = try await mapManifestsProject(
            projectManifests: projectManifests,
            projectDescriptionPath: projectDescriptionSearchPath,
            swiftVersion: swiftVersion,
            sourceRootPath: sourceRootPath,
            destinationDirectory: destinationDirectory,
            tuistPath: tuistPath,
            helpers: helpers,
            templateSources: templateSources,
            templateResources: templateResources,
            resourceSynthesizers: resourceSynthesizers,
            stencils: stencils,
            configPath: configPath,
            packageManifestPath: packageManifestPath,
            editablePluginTargets: editablePluginManifests.map(\.name),
            pluginProjectDescriptionHelpersModule: pluginProjectDescriptionHelpersModule
        )

        let projects = [pluginsProject, manifestsProject].compactMap { $0 }

        let workspace = Workspace(
            path: sourceRootPath,
            xcWorkspacePath: destinationDirectory.appending(component: "\(name).xcworkspace"),
            name: name,
            projects: projects.map(\.path),
            generationOptions: .init(
                enableAutomaticXcodeSchemes: false,
                autogeneratedWorkspaceSchemes: .enabled(codeCoverageMode: .disabled, testingOptions: []),
                lastXcodeUpgradeCheck: nil,
                renderMarkdownReadme: false
            )
        )

        let graphProjects = Dictionary(uniqueKeysWithValues: projects.map { ($0.path, $0) })

        let graphDependencies = projects
            .lazy
            .flatMap { project -> [(GraphDependency, Set<GraphDependency>)] in
                let graphDependencies = project.targets.values.map(\.dependencies).lazy.map { dependencies in
                    dependencies.lazy.compactMap { dependency -> GraphDependency? in
                        switch dependency {
                        case let .target(name, _, _):
                            if let pluginsProject, editablePluginManifests.contains(where: { $0.name == name }) {
                                return .target(name: name, path: pluginsProject.path)
                            } else {
                                return .target(name: name, path: project.path)
                            }
                        default:
                            return nil
                        }
                    }
                }

                return zip(project.targets.values, graphDependencies).map { target, dependencies in
                    (GraphDependency.target(name: target.name, path: project.path), Set(dependencies))
                }
            }

        return Graph(
            name: name,
            path: sourceRootPath,
            workspace: workspace,
            projects: graphProjects,
            packages: [:],
            dependencies: Dictionary(uniqueKeysWithValues: graphDependencies),
            dependencyConditions: [:]
        )
    }

    // swiftlint:disable:next function_body_length
    private func mapManifestsProject(
        projectManifests: [AbsolutePath],
        projectDescriptionPath: AbsolutePath,
        swiftVersion: String,
        sourceRootPath: AbsolutePath,
        destinationDirectory: AbsolutePath,
        tuistPath: AbsolutePath,
        helpers: [AbsolutePath],
        templateSources: [AbsolutePath],
        templateResources: [AbsolutePath],
        resourceSynthesizers: [AbsolutePath],
        stencils: [AbsolutePath],
        configPath: AbsolutePath?,
        packageManifestPath: AbsolutePath?,
        editablePluginTargets: [String],
        pluginProjectDescriptionHelpersModule: [ProjectDescriptionHelpersModule]
    ) async throws -> Project? {
        guard !projectManifests.isEmpty || packageManifestPath != nil else { return nil }

        let projectName = "Manifests"
        let projectPath = sourceRootPath.appending(component: projectName)
        let manifestsFilesGroup = ProjectGroup.group(name: projectName)
        let baseTargetSettings = Settings(
            base: targetBaseSettings(
                projectFrameworkPath: projectDescriptionPath,
                pluginHelperLibraryPaths: [],
                swiftVersion: swiftVersion
            ),
            configurations: Settings.default.configurations,
            defaultSettings: .recommended
        )

        let configTarget: Target? = {
            guard let configPath else { return nil }
            return editorHelperTarget(
                name: "Config",
                filesGroup: manifestsFilesGroup,
                targetSettings: baseTargetSettings,
                sourcePaths: [configPath]
            )
        }()

        let editablePluginTargetDependencies = editablePluginTargets.map { TargetDependency.target(name: $0) }
        let targetWithLinkedPluginsSettings = Settings(
            base: targetBaseSettings(
                projectFrameworkPath: projectDescriptionPath,
                pluginHelperLibraryPaths: pluginProjectDescriptionHelpersModule.map(\.path),
                swiftVersion: swiftVersion
            ),
            configurations: Settings.default.configurations,
            defaultSettings: .recommended
        )

        let helpersTarget: Target? = {
            guard !helpers.isEmpty else { return nil }
            return editorHelperTarget(
                name: Constants.helpersDirectoryName,
                filesGroup: manifestsFilesGroup,
                targetSettings: targetWithLinkedPluginsSettings,
                sourcePaths: helpers,
                dependencies: editablePluginTargetDependencies
            )
        }()

        let templatesTarget: Target? = {
            let generateTemplateTarget = !templateSources.isEmpty || !templateResources.isEmpty
            guard generateTemplateTarget else { return nil }
            return editorHelperTarget(
                name: Constants.templatesDirectoryName,
                filesGroup: manifestsFilesGroup,
                targetSettings: baseTargetSettings,
                sourcePaths: templateSources,
                additionalFilePaths: templateResources,
                dependencies: helpersTarget.flatMap { [TargetDependency.target(name: $0.name)] } ?? []
            )
        }()

        let resourceSynthesizersTarget: Target? = {
            guard !resourceSynthesizers.isEmpty else { return nil }
            return editorHelperTarget(
                name: Constants.resourceSynthesizersDirectoryName,
                filesGroup: manifestsFilesGroup,
                targetSettings: baseTargetSettings,
                sourcePaths: [],
                additionalFilePaths: resourceSynthesizers,
                dependencies: helpersTarget.flatMap { [TargetDependency.target(name: $0.name)] } ?? []
            )
        }()

        let stencilsTarget: Target? = {
            guard !stencils.isEmpty else { return nil }
            return editorHelperTarget(
                name: Constants.stencilsDirectoryName,
                filesGroup: manifestsFilesGroup,
                targetSettings: baseTargetSettings,
                sourcePaths: stencils,
                dependencies: helpersTarget.flatMap { [TargetDependency.target(name: $0.name)] } ?? []
            )
        }()

        let helperTargetDependencies = helpersTarget.map { [TargetDependency.target(name: $0.name)] } ?? []
        let helperAndPluginDependencies = helperTargetDependencies + editablePluginTargetDependencies

        let packagesTarget: Target? = try await {
            guard let packageManifestPath,
                  let xcode = try await XcodeController.shared.selected()
            else { return nil }
            let packageVersion = try swiftPackageManagerController.getToolsVersion(at: packageManifestPath.parentDirectory)

            var packagesSettings = targetBaseSettings(
                projectFrameworkPath: projectDescriptionPath,
                pluginHelperLibraryPaths: pluginProjectDescriptionHelpersModule.map(\.path),
                swiftVersion: swiftVersion
            )
            packagesSettings.merge(
                [
                    "OTHER_SWIFT_FLAGS": .array([
                        "-package-description-version",
                        packageVersion.description,
                        "-D", "TUIST",
                    ]),
                    "SWIFT_INCLUDE_PATHS": .array([
                        "\(xcode.path.pathString)/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI",
                    ]),
                ],
                uniquingKeysWith: {
                    switch ($0, $1) {
                    case let (.array(leftArray), .array(rightArray)):
                        return SettingValue.array(leftArray + rightArray)
                    default:
                        return $1
                    }
                }
            )

            let dependencies: [TargetDependency] = helpersTarget == nil ? [] : [
                .target(name: "ProjectDescriptionHelpers"),
            ]

            return editorHelperTarget(
                name: "Packages",
                filesGroup: manifestsFilesGroup,
                targetSettings: Settings(
                    base: packagesSettings,
                    configurations: Settings.default.configurations,
                    defaultSettings: .recommended
                ),
                sourcePaths: [packageManifestPath],
                dependencies: dependencies
            )
        }()

        let manifestsTargets = namedManifests(projectManifests).map { name, projectManifestSourcePath -> Target in
            editorHelperTarget(
                name: name,
                filesGroup: manifestsFilesGroup,
                targetSettings: targetWithLinkedPluginsSettings,
                sourcePaths: [projectManifestSourcePath],
                dependencies: helperAndPluginDependencies
            )
        }

        let targets = [
            helpersTarget,
            templatesTarget,
            resourceSynthesizersTarget,
            stencilsTarget,
            configTarget,
            packagesTarget,
        ]
        .compactMap { $0 }
        + manifestsTargets

        let buildAction = BuildAction(targets: targets.map { TargetReference(projectPath: projectPath, name: $0.name) })
        let arguments = Arguments(launchArguments: [LaunchArgument(name: "generate --path \(sourceRootPath)", isEnabled: true)])
        let runAction = RunAction(
            configurationName: "Debug",
            attachDebugger: true,
            customLLDBInitFile: nil,
            executable: nil,
            filePath: tuistPath,
            arguments: arguments,
            diagnosticsOptions: SchemeDiagnosticsOptions()
        )
        let scheme = Scheme(name: projectName, shared: true, buildAction: buildAction, runAction: runAction)
        let projectSettings = Settings(
            base: [:],
            configurations: Settings.default.configurations,
            defaultSettings: .recommended
        )

        return Project(
            path: projectPath,
            sourceRootPath: sourceRootPath,
            xcodeProjPath: destinationDirectory.appending(component: "\(projectName).xcodeproj"),
            name: projectName,
            organizationName: nil,
            classPrefix: nil,
            defaultKnownRegions: nil,
            developmentRegion: nil,
            options: .init(
                automaticSchemesOptions: .disabled,
                disableBundleAccessors: true,
                disableShowEnvironmentVarsInScriptPhases: false,
                disableSynthesizedResourceAccessors: true,
                textSettings: .init(usesTabs: nil, indentWidth: nil, tabWidth: nil, wrapsLines: nil)
            ),
            settings: projectSettings,
            filesGroup: manifestsFilesGroup,
            targets: targets,
            packages: [],
            schemes: [scheme],
            ideTemplateMacros: nil,
            additionalFiles: [],
            resourceSynthesizers: [],
            lastUpgradeCheck: nil,
            type: .local
        )
    }

    // swiftlint:disable:next function_body_length
    private func mapPluginsProject(
        pluginManifests: [EditablePluginManifest],
        projectDescriptionPath: AbsolutePath,
        swiftVersion: String,
        sourceRootPath: AbsolutePath,
        destinationDirectory: AbsolutePath,
        tuistPath _: AbsolutePath
    ) async throws -> Project? {
        guard !pluginManifests.isEmpty else { return nil }

        let projectName = "Plugins"
        let projectPath = sourceRootPath.appending(component: projectName)
        let pluginsFilesGroup = ProjectGroup.group(name: projectName)
        let targetSettings = Settings(
            base: targetBaseSettings(
                projectFrameworkPath: projectDescriptionPath,
                pluginHelperLibraryPaths: [],
                swiftVersion: swiftVersion
            ),
            configurations: Settings.default.configurations,
            defaultSettings: .recommended
        )

        let fileSystem = fileSystem
        let pluginTargets = try await pluginManifests.concurrentMap { manifest -> Target in
            let pluginManifest = manifest.path.appending(component: "Plugin.swift")
            let pluginHelpersPath = manifest.path.appending(component: Constants.helpersDirectoryName)
            let pluginTemplatesPath = manifest.path.appending(component: Constants.templatesDirectoryName)
            let pluginResourceTemplatesPath = manifest.path.appending(component: Constants.resourceSynthesizersDirectoryName)
            let pluginHelpers = try await fileSystem.glob(directory: pluginHelpersPath, include: ["**/*.swift"])
                .collect()
            let pluginTemplates = try await fileSystem.glob(
                directory: pluginTemplatesPath,
                include: ["**/*.swift", "**/*.stencil"]
            ).collect()
            let pluginResources = try await fileSystem.glob(directory: pluginResourceTemplatesPath, include: ["*.stencil"])
                .collect()
            let sourcePaths = [pluginManifest] + pluginHelpers + pluginTemplates + pluginResources
            return self.editorHelperTarget(
                name: manifest.name,
                filesGroup: pluginsFilesGroup,
                targetSettings: targetSettings,
                sourcePaths: sourcePaths,
                dependencies: []
            )
        }

        let schemes = pluginTargets.map { target -> Scheme in
            let buildAction = BuildAction(targets: [TargetReference(projectPath: projectPath, name: target.name)])
            return Scheme(name: target.name, shared: true, buildAction: buildAction, runAction: nil)
        }

        let allPluginsScheme = Scheme(
            name: "Plugins",
            shared: true,
            buildAction: BuildAction(targets: pluginTargets.map { TargetReference(projectPath: projectPath, name: $0.name) }),
            runAction: nil
        )

        let allSchemes = schemes + [allPluginsScheme]

        let projectSettings = Settings(
            base: [:],
            configurations: Settings.default.configurations,
            defaultSettings: .recommended
        )

        return Project(
            path: projectPath,
            sourceRootPath: sourceRootPath,
            xcodeProjPath: destinationDirectory.appending(component: "\(projectName).xcodeproj"),
            name: projectName,
            organizationName: nil,
            classPrefix: nil,
            defaultKnownRegions: nil,
            developmentRegion: nil,
            options: .init(
                automaticSchemesOptions: .disabled,
                disableBundleAccessors: true,
                disableShowEnvironmentVarsInScriptPhases: false,
                disableSynthesizedResourceAccessors: true,
                textSettings: .init(usesTabs: nil, indentWidth: nil, tabWidth: nil, wrapsLines: nil)
            ),
            settings: projectSettings,
            filesGroup: pluginsFilesGroup,
            targets: pluginTargets,
            packages: [],
            schemes: allSchemes,
            ideTemplateMacros: nil,
            additionalFiles: [],
            resourceSynthesizers: [],
            lastUpgradeCheck: nil,
            type: .local
        )
    }

    /// Collects all targets into a dictionary where each key is a reference to a target
    /// which maps to a set of target references representing the target's dependencies.
    /// - Parameters:
    ///   - targets: The targets to map to their dependencies.
    ///   - projectPath: The path to the project where the targets are defined.
    /// - Returns: dictionary where each key is a reference to a target and value is the target's dependencies.
    private func mapTargetsToDependencies(
        targets: [Target],
        projectPath: AbsolutePath
    ) -> [TargetReference: Set<TargetReference>] {
        targets.reduce(into: [TargetReference: Set<TargetReference>]()) { result, target in
            let dependencyRefs = target.dependencies.lazy.compactMap { dependency -> TargetReference? in
                switch dependency {
                case let .target(name, _, _):
                    return TargetReference(projectPath: projectPath, name: name)
                default:
                    return nil
                }
            }
            result[TargetReference(projectPath: projectPath, name: target.name)] = Set(dependencyRefs)
        }
    }

    /// It returns a dictionary with unique name as key for each Manifest file
    /// - Parameter manifests: Manifest files to assign an unique name
    /// - Returns: Dictionary composed by unique name as key and Manifest file as value.
    private func namedManifests(_ manifests: [AbsolutePath]) -> [String: AbsolutePath] {
        manifests.reduce(into: [String: AbsolutePath]()) { result, manifest in
            var name = "\(manifest.parentDirectory.basename)Manifests"
            while result[name] != nil {
                name = "_\(name)"
            }
            result[name] = manifest
        }
    }

    /// It returns a target for edit project.
    /// - Parameters:
    ///   - name: Name for the target.
    ///   - filesGroup: File group for target.
    ///   - targetSettings: Target's settings.
    ///   - sourcePaths: Target's sources.
    ///   - dependencies: Target's dependencies.
    /// - Returns: Target for edit project.
    private func editorHelperTarget(
        name: String,
        filesGroup: ProjectGroup,
        targetSettings: Settings,
        sourcePaths: [AbsolutePath],
        additionalFilePaths: [AbsolutePath] = [],
        dependencies: [TargetDependency] = []
    ) -> Target {
        Target(
            name: name,
            destinations: .macOS,
            product: .staticFramework,
            productName: name,
            bundleId: "io.tuist.${PRODUCT_NAME:rfc1034identifier}",
            settings: targetSettings,
            sources: sourcePaths.map { SourceFile(path: $0, compilerFlags: nil) },
            filesGroup: filesGroup,
            dependencies: dependencies,
            additionalFiles: additionalFilePaths.map { .file(path: $0) }
        )
    }

    /// Returns a ``SettingsDictionary`` which includes the base settings for a target.
    /// Base settings include things such as: the search paths for the given `includes` and the Swift version.
    private func targetBaseSettings(
        projectFrameworkPath: AbsolutePath,
        pluginHelperLibraryPaths: [AbsolutePath],
        swiftVersion: String
    ) -> SettingsDictionary {
        // In development, the .swiftmodule is generated in a directory up from the directory of the framework.
        // /path/to/derived/tuist-xyz/
        //    PackageFrameworks/
        //      ProjectDescription.framework
        //    ProjectDescription.swiftmodule
        // Because of that we need to expose the parent directory too in SWIFT_INCLUDE_PATHS
        let projectFrameworkSearchPaths = [projectFrameworkPath, projectFrameworkPath.parentDirectory]
        let pluginHelperSearchPaths = pluginHelperLibraryPaths.map(\.parentDirectory)
        let includePaths = (projectFrameworkSearchPaths + pluginHelperSearchPaths).map { "\"\($0)\"" }
        return [
            "FRAMEWORK_SEARCH_PATHS": .array(includePaths),
            "LIBRARY_SEARCH_PATHS": .array(includePaths),
            "SWIFT_INCLUDE_PATHS": .array(includePaths),
            "SWIFT_VERSION": .string(swiftVersion),
        ]
    }
}
