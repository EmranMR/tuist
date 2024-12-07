import Foundation
import Path
import TuistCore
import XcodeGraph

/// A project mapper that auto-generates schemes for each of the targets of the `Project`
/// if the user hasn't already defined schemes for those.
public final class AutogeneratedSchemesProjectMapper: ProjectMapping { // swiftlint:disable:this type_body_length
    // MARK: - Init

    public init() {}

    // MARK: - ProjectMapping

    // swiftlint:disable:next function_body_length
    public func map(project: Project) throws -> (Project, [SideEffectDescriptor]) {
        logger.debug("Transforming project \(project.name): Auto-generating project schemes")

        let userDefinedSchemes = project.schemes
        let userDefinedSchemeNames = Set(project.schemes.map(\.name))

        var buildTargets: Set<Target> = []
        var testTargets: Set<Target> = []
        var runTargets: Set<Target> = []
        for target in project.targets.values.sorted() {
            switch target.product {
            case .app, .appClip, .commandLineTool, .watch2App, .xpc:
                runTargets.insert(target)
            case .uiTests, .unitTests:
                testTargets.insert(target)
            case .framework, .staticLibrary, .dynamicLibrary, .staticFramework, .bundle, .appExtension, .watch2Extension,
                 .tvTopShelfExtension, .messagesExtension, .stickerPackExtension, .systemExtension, .extensionKitExtension,
                 .macro:
                buildTargets.insert(target)
            }
        }

        // swiftlint:disable:next large_tuple
        let targetGroups: [String: (build: Set<Target>, test: Set<Target>, run: Set<Target>)]
        switch project.options.targetSchemesGrouping {
        case .singleScheme:
            targetGroups = [
                project.name: (
                    build: buildTargets,
                    test: testTargets,
                    run: runTargets
                ),
            ]
        case let .byNameSuffix(buildSuffixes, testSuffixes, runSuffixes):
            targetGroups = groupByName(
                buildTargets: &buildTargets,
                testTargets: &testTargets,
                runTargets: &runTargets,
                buildSuffixes: buildSuffixes,
                testSuffixes: testSuffixes,
                runSuffixes: runSuffixes
            )
        case .notGrouped:
            targetGroups = [:]
        case .none:
            return (project, [])
        }

        let autogeneratedSchemes: [Scheme]
        if !targetGroups.isEmpty {
            autogeneratedSchemes = targetGroups.map { name, targets in
                createDefaultScheme(
                    name: name,
                    project: project,
                    buildTargets: targets.build,
                    testTargets: targets.test,
                    runTargets: targets.run,
                    buildConfiguration: project.defaultDebugBuildConfigurationName
                )
            }
        } else {
            let remainingBuildTargetsSchemes = buildTargets.map {
                createDefaultScheme(
                    name: $0.name,
                    project: project,
                    buildTargets: [$0],
                    testTargets: [],
                    runTargets: [],
                    buildConfiguration: project.defaultDebugBuildConfigurationName
                )
            }
            let remainingTestTargetsSchemes = testTargets.map {
                createDefaultScheme(
                    name: $0.name,
                    project: project,
                    buildTargets: [],
                    testTargets: [$0],
                    runTargets: [],
                    buildConfiguration: project.defaultDebugBuildConfigurationName
                )
            }
            let remainingRunTargetsSchemes = runTargets.map {
                createDefaultScheme(
                    name: $0.name,
                    project: project,
                    buildTargets: [],
                    testTargets: [],
                    runTargets: [$0],
                    buildConfiguration: project.defaultDebugBuildConfigurationName
                )
            }
            autogeneratedSchemes = remainingBuildTargetsSchemes + remainingTestTargetsSchemes + remainingRunTargetsSchemes
        }

        let filteredAutogeneratedSchemes = autogeneratedSchemes.filter { !userDefinedSchemeNames.contains($0.name) }
        var project = project
        project.schemes = (userDefinedSchemes + filteredAutogeneratedSchemes).sorted { $0.name < $1.name }
        return (project, [])
    }

    // MARK: - Private

    // swiftlint:disable:next function_body_length
    private func createDefaultScheme(
        name: String,
        project: Project,
        buildTargets: Set<Target>,
        testTargets: Set<Target>,
        runTargets: Set<Target>,
        buildConfiguration: String
    ) -> Scheme {
        var actualRunTarget: Target?

        if runTargets.count == 1,
           let runTarget = runTargets.first
        {
            actualRunTarget = runTarget
        } else {
            if let extensionTarget = buildTargets
                .first(where: { $0.product == .appExtension || $0.product == .messagesExtension })
            {
                actualRunTarget = hostAppTargetReference(for: extensionTarget, project: project)
            } else if let watch2ExtensionTarget = buildTargets.first(where: { $0.product == .watch2Extension }) {
                actualRunTarget = hostWatchAppTargetReference(for: watch2ExtensionTarget, project: project)
            } else {
                actualRunTarget = nil
            }
        }

        let runAction = actualRunTarget.map {
            RunAction(
                configurationName: buildConfiguration,
                attachDebugger: true,
                customLLDBInitFile: nil,
                preActions: [],
                postActions: [],
                executable: .init(projectPath: project.path, name: $0.name),
                filePath: nil,
                arguments: defaultArguments(for: $0),
                options: .init(
                    language: project.options.runLanguage,
                    region: project.options.runRegion
                ),
                diagnosticsOptions: SchemeDiagnosticsOptions(
                    mainThreadCheckerEnabled: true,
                    performanceAntipatternCheckerEnabled: true
                ),
                metalOptions: MetalOptions(
                    apiValidation: true
                )
            )
        }

        // build targets should be first, because in case of extension schemes, the extension target should be the first one
        var buildTargetReferences = (
            buildTargets.sorted { $0.name < $1.name } + runTargets.sorted { $0.name < $1.name }
        )
        .map {
            TargetReference(projectPath: project.path, name: $0.name)
        }
        if let runActionTargetReference = runAction?.executable,
           !buildTargetReferences.contains(runActionTargetReference)
        {
            buildTargetReferences.append(runActionTargetReference)
        }

        let testableTargets: [TestableTarget] = testTargets
            .map {
                let parallel = project.options.testingOptions.contains(.parallelizable)
                let randomExecution = project.options.testingOptions.contains(.randomExecutionOrdering)
                return TestableTarget(
                    target: .init(projectPath: project.path, name: $0.name),
                    parallelizable: parallel,
                    randomExecutionOrdering: randomExecution
                )
            }
            .sorted { $0.target.name < $1.target.name }

        let buildAction: BuildAction
        if buildTargetReferences.isEmpty {
            buildAction = .init(targets: testableTargets.map(\.target))
        } else {
            buildAction = .init(targets: buildTargetReferences)
        }
        return Scheme(
            name: name,
            shared: true,
            buildAction: buildAction,
            testAction: testableTargets.isEmpty ? nil : TestAction(
                targets: testableTargets,
                arguments: defaultArguments(for: testTargets.sorted { $0.name < $1.name }),
                configurationName: buildConfiguration,
                attachDebugger: true,
                coverage: project.options.codeCoverageEnabled,
                codeCoverageTargets: [],
                expandVariableFromTarget: nil,
                preActions: [],
                postActions: [],
                diagnosticsOptions: SchemeDiagnosticsOptions(mainThreadCheckerEnabled: true),
                language: project.options.testLanguage,
                region: project.options.testRegion,
                preferredScreenCaptureFormat: project.options.testScreenCaptureFormat
            ),
            runAction: runAction
        )
    }

    private func defaultArguments(for targets: [Target]) -> Arguments? {
        targets.reduce(nil) { partialResult, target in
            guard let arguments = defaultArguments(for: target) else { return partialResult }
            guard let partialResult else { return arguments }
            return partialResult.merging(with: arguments)
        }
    }

    private func defaultArguments(for target: Target) -> Arguments? {
        if target.environmentVariables.isEmpty, target.launchArguments.isEmpty {
            return nil
        }
        return Arguments(environmentVariables: target.environmentVariables, launchArguments: target.launchArguments)
    }

    // swiftlint:disable:next function_body_length
    private func groupByName(
        buildTargets: inout Set<Target>,
        testTargets: inout Set<Target>,
        runTargets: inout Set<Target>,
        buildSuffixes: Set<String>,
        testSuffixes: Set<String>,
        runSuffixes: Set<String>
    ) -> [String: (build: Set<Target>, test: Set<Target>, run: Set<Target>)] { // swiftlint:disable:this large_tuple
        let longerFirst: (String, String) -> Bool = { $0.count > $1.count }
        let sortedBuildSuffixes = (buildSuffixes + [""]).sorted(by: longerFirst)
        let sortedTestSuffixes = (testSuffixes + [""]).sorted(by: longerFirst)
        let sortedRunSuffixes = (runSuffixes + [""]).sorted(by: longerFirst)
        let groupToBuildTargets: [String: Set<Target>] = buildTargets
            .map { target -> (name: String, target: Target) in
                for buildSuffix in sortedBuildSuffixes where target.name.hasSuffix(buildSuffix) {
                    let groupName = String(target.name.dropSuffix(buildSuffix))
                    buildTargets.remove(target)
                    return (name: groupName, target: target)
                }
                return (name: target.name, target: target)
            }
            .reduce(into: [:]) { result, nameAndTarget in
                result[nameAndTarget.name, default: []].insert(nameAndTarget.target)
            }

        let groupToTestTargets: [String: Set<Target>] = testTargets
            .map { target -> (name: String, target: Target) in
                for testSuffix in sortedTestSuffixes where target.name.hasSuffix(testSuffix) {
                    let groupName = String(target.name.dropSuffix(testSuffix))
                    testTargets.remove(target)
                    return (name: groupName, target: target)
                }
                return (name: target.name, target: target)
            }
            .reduce(into: [:]) { result, nameAndTarget in
                result[nameAndTarget.name, default: []].insert(nameAndTarget.target)
            }

        let groupToRunTargets: [String: Set<Target>] = runTargets
            .map { target -> (name: String, target: Target) in
                for runSuffix in sortedRunSuffixes where target.name.hasSuffix(runSuffix) {
                    let groupName: String
                    if groupToBuildTargets[target.name] != nil || groupToTestTargets[target.name] != nil {
                        // For example, if there is already a `MyAppTests` group, don't group the `MyApp` target in a separate
                        // `My` group, but use the same for both
                        groupName = target.name
                    } else {
                        groupName = String(target.name.dropSuffix(runSuffix))
                    }
                    runTargets.remove(target)
                    return (name: groupName, target: target)
                }
                return (name: target.name, target: target)
            }
            .reduce(into: [:]) { result, nameAndTarget in
                result[nameAndTarget.name, default: []].insert(nameAndTarget.target)
            }

        let allGroupNames = Set(groupToBuildTargets.keys).union(groupToTestTargets.keys).union(groupToRunTargets.keys)
        return Dictionary(uniqueKeysWithValues: allGroupNames.map { name in
            let buildTargets = groupToBuildTargets[name] ?? []
            let testTargets = groupToTestTargets[name] ?? []
            let runTargets = groupToRunTargets[name] ?? []
            let schemeName: String

            let targetsCount = buildTargets.count + testTargets.count + runTargets.count
            if targetsCount == 1 {
                // use target name as scheme name
                let singleTarget = buildTargets.first ?? testTargets.first ?? runTargets.first
                schemeName = singleTarget!.name // swiftlint:disable:this force_unwrapping
            } else {
                schemeName = name
            }
            return (
                schemeName,
                (
                    build: buildTargets,
                    test: testTargets,
                    run: runTargets
                )
            )
        })
    }

    private func hostAppTargetReference(for target: Target, project: Project) -> Target? {
        project.targets
            .values
            .filter { $0.product.canHostTests() && $0.dependencies.contains(where: { dependency in
                if case let .target(name, _, _) = dependency, name == target.name {
                    return true
                } else {
                    return false
                }
            }) }
            .sorted { $0.name < $1.name }
            .first
    }

    private func hostWatchAppTargetReference(for target: Target, project: Project) -> Target? {
        project.targets
            .values
            .filter { $0.product == .watch2App && $0.dependencies.contains(where: { dependency in
                if case let .target(name, _, _) = dependency, name == target.name {
                    return true
                } else {
                    return false
                }
            }) }
            .sorted { $0.name < $1.name }
            .first
    }
}

extension Product {
    var isExtension: Bool {
        switch self {
        case .appExtension, .watch2Extension, .tvTopShelfExtension, .messagesExtension, .stickerPackExtension, .systemExtension,
             .extensionKitExtension:
            return true
        case .staticFramework, .app, .appClip, .staticLibrary, .dynamicLibrary, .framework, .unitTests, .uiTests, .bundle,
             .commandLineTool, .watch2App, .xpc, .macro:
            return false
        }
    }
}

extension Arguments {
    /// Creates a new `Arguments` that merges the contents of the current and given `Arguments`.
    ///
    /// If there are duplicate keys, the value of the current one will be preserved.
    ///
    /// - Parameter arguments: The `Arguments` to merge.
    /// - Returns: A new `Arguments` with the merged contents.
    func merging(with arguments: Arguments) -> Arguments {
        Arguments(
            environmentVariables: environmentVariables.merging(
                arguments.environmentVariables,
                uniquingKeysWith: { a, _ in a }
            ),
            launchArguments: launchArguments + arguments.launchArguments.filter { argument in
                !self.launchArguments.contains(where: { argument.name == $0.name })
            }
        )
    }
}
