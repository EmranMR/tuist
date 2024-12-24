import FileSystem
import Path
import struct TSCUtility.Version
import TuistCore
import TuistSupport
import XcodeGraph
import ServiceContextModule

public protocol TargetRunning {
    /// Runs a provided target.
    ///
    /// - Parameters:
    ///   - target: The target to run.
    ///   - workspacePath: The path to the `.xcworkspace` where the target is defined.
    ///   - schemeName: The name of the scheme where the target is defined.
    ///   - configuration: The configuration to use while building the target.
    ///   - version: Specific version, ignored if nil
    ///   - minVersion: Minimum version of the OS
    ///   - deviceName: The name of the simulator device to run the target on, if none provided uses a default device.
    ///   - arguments: Arguments to forward to the runnable target when running.
    func runTarget(
        _ target: GraphTarget,
        platform: XcodeGraph.Platform,
        workspacePath: AbsolutePath,
        schemeName: String,
        configuration: String?,
        minVersion: Version?,
        version: Version?,
        deviceName: String?,
        arguments: [String]
    ) async throws

    /// Given a target, if it is not supported for running throws an error.
    /// - Parameter target: The target to check if supported.
    func assertCanRunTarget(_ target: Target) throws
}

public enum TargetRunnerError: Equatable, FatalError {
    case runnableNotFound(path: String)
    case runningNotSupported(target: Target)
    case targetNotRunnableOnPlatform(target: Target, platform: Platform)

    public var type: ErrorType {
        switch self {
        case .runningNotSupported, .targetNotRunnableOnPlatform:
            return .abort
        case .runnableNotFound:
            return .bug
        }
    }

    public var description: String {
        switch self {
        case let .runningNotSupported(target):
            return "Product type \(target.product.caseValue) of \(target.name) is not runnable"
        case let .targetNotRunnableOnPlatform(target, platform):
            return "Cannot run \(target.name) - the platform \(platform.rawValue) and product type \(target.product.caseValue) are not currently supported."
        case let .runnableNotFound(path):
            return "The runnable product was expected but not found at \(path)."
        }
    }
}

public final class TargetRunner: TargetRunning {
    private let xcodeBuildController: XcodeBuildControlling
    private let xcodeProjectBuildDirectoryLocator: XcodeProjectBuildDirectoryLocating
    private let simulatorController: SimulatorControlling
    private let fileSystem: FileSysteming

    public init(
        xcodeBuildController: XcodeBuildControlling = XcodeBuildController(),
        xcodeProjectBuildDirectoryLocator: XcodeProjectBuildDirectoryLocating = XcodeProjectBuildDirectoryLocator(),
        simulatorController: SimulatorControlling = SimulatorController(),
        fileSystem: FileSysteming = FileSystem()
    ) {
        self.xcodeBuildController = xcodeBuildController
        self.xcodeProjectBuildDirectoryLocator = xcodeProjectBuildDirectoryLocator
        self.simulatorController = simulatorController
        self.fileSystem = fileSystem
    }

    public func runTarget(
        _ target: GraphTarget,
        platform: XcodeGraph.Platform,
        workspacePath: AbsolutePath,
        schemeName: String,
        configuration: String?,
        minVersion: Version?,
        version: Version?,
        deviceName: String?,
        arguments: [String]
    ) async throws {
        try assertCanRunTarget(target.target)

        let configuration = configuration ?? target.project.settings.defaultDebugBuildConfiguration()?.name ?? BuildConfiguration
            .debug.name
        let xcodeBuildDirectory = try xcodeProjectBuildDirectoryLocator.locate(
            destinationType: .simulator(platform),
            projectPath: workspacePath,
            derivedDataPath: nil,
            configuration: configuration
        )
        let runnablePath = xcodeBuildDirectory.appending(component: target.target.productNameWithExtension)
        guard try await fileSystem.exists(runnablePath) else {
            throw TargetRunnerError.runnableNotFound(path: runnablePath.pathString)
        }

        switch (platform, target.target.product) {
        case (.macOS, .commandLineTool):
            try runExecutable(runnablePath, arguments: arguments)
        case let (platform, .app):
            try await runApp(
                target: target,
                schemeName: schemeName,
                configuration: configuration,
                appPath: runnablePath,
                workspacePath: workspacePath,
                platform: platform,
                minVersion: minVersion,
                version: version,
                deviceName: deviceName,
                arguments: arguments
            )
        default:
            throw TargetRunnerError.targetNotRunnableOnPlatform(target: target.target, platform: platform)
        }
    }

    public func assertCanRunTarget(_ target: Target) throws {
        switch target.product {
        case .commandLineTool,
             .xpc,
             .app:
            break
        default:
            throw TargetRunnerError.runningNotSupported(target: target)
        }
    }

    private func runExecutable(_ executablePath: AbsolutePath, arguments: [String]) throws {
        ServiceContext.current?.logger?.notice("Running executable \(executablePath.basename)", metadata: .section)
        ServiceContext.current?.logger?.debug("Forwarding arguments: \(arguments.joined(separator: ", "))")
        try System.shared.runAndPrint([executablePath.pathString] + arguments)
    }

    private func runApp(
        target: GraphTarget,
        schemeName: String,
        configuration: String,
        appPath: AbsolutePath,
        workspacePath: AbsolutePath,
        platform: Platform,
        minVersion: Version?,
        version: Version?,
        deviceName: String?,
        arguments: [String]
    ) async throws {
        let settings = try await xcodeBuildController
            .showBuildSettings(.workspace(workspacePath), scheme: schemeName, configuration: configuration, derivedDataPath: nil)
        let bundleId = settings[target.target.name]?.productBundleIdentifier ?? target.target.bundleId
        let simulator = try await simulatorController.askForAvailableDevice(
            platform: platform,
            version: version,
            minVersion: minVersion,
            deviceName: deviceName
        )

        ServiceContext.current?.logger?.debug("Running app \(appPath.pathString) with arguments [\(arguments.joined(separator: ", "))]")
        ServiceContext.current?.logger?.notice("Running app \(bundleId) on \(simulator.device.name)", metadata: .section)
        try simulatorController.installApp(at: appPath, device: simulator.device)
        try await simulatorController.launchApp(bundleId: bundleId, device: simulator.device, arguments: arguments)
    }
}
