#!/usr/bin/env python3
"""Generate the checked-in multiplatform Xcode project using only Python's stdlib."""
from pathlib import Path
import hashlib

root = Path(__file__).resolve().parents[1] / "app"
def uid(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def ref(name): return uid(name)
objects = []
def obj(name, value): objects.append(f"\t\t{uid(name)} = {{ {value} }};")

files = sorted((root / "Sources/ReaderApp").glob("*.swift"))
for file in files:
    obj(file.name, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "Sources/ReaderApp/{file.name}"; sourceTree = "<group>";')
    obj("build:" + file.name, f'isa = PBXBuildFile; fileRef = {ref(file.name)};')
obj("app", 'isa = PBXFileReference; explicitFileType = wrapper.application; path = Margin.app; sourceTree = BUILT_PRODUCTS_DIR;')
obj("info", 'isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>";')
obj("assets", 'isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Resources/Assets.xcassets; sourceTree = "<group>";')
obj("assets-build", f'isa = PBXBuildFile; fileRef = {ref("assets")};')
obj("main", f'isa = PBXGroup; children = ({", ".join(ref(f.name) for f in files)}, {ref("assets")}, {ref("info")}, {ref("products")}); sourceTree = "<group>";')
obj("products", f'isa = PBXGroup; children = ({ref("app")}); name = Products; sourceTree = "<group>";')
obj("sources", f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({", ".join(ref("build:" + f.name) for f in files)}); runOnlyForDeploymentPostprocessing = 0;')
obj("core-build", f'isa = PBXBuildFile; productRef = {ref("core")};')
obj("frameworks", f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({ref("core-build")}); runOnlyForDeploymentPostprocessing = 0;')
obj("resources", f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({ref("assets-build")}); runOnlyForDeploymentPostprocessing = 0;')
obj("package", 'isa = XCLocalSwiftPackageReference; relativePath = ".";')
obj("core", f'isa = XCSwiftPackageProductDependency; package = {ref("package")}; productName = LibraryCore;')
obj("target", f'isa = PBXNativeTarget; buildConfigurationList = {ref("target-config")}; buildPhases = ({ref("sources")}, {ref("frameworks")}, {ref("resources")}); buildRules = (); dependencies = (); name = Margin; packageProductDependencies = ({ref("core")}); productName = Margin; productReference = {ref("app")}; productType = "com.apple.product-type.application";')
obj("project", f'isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 1600; }}; buildConfigurationList = {ref("project-config")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = {ref("main")}; packageReferences = ({ref("package")}); productRefGroup = {ref("products")}; projectDirPath = ""; projectRoot = ""; targets = ({ref("target")});')
for config in ("Debug", "Release"):
    obj("project-" + config, f'isa = XCBuildConfiguration; buildSettings = {{ CLANG_ENABLE_MODULES = YES; ONLY_ACTIVE_ARCH = YES; SWIFT_VERSION = 5.0; MACOSX_DEPLOYMENT_TARGET = 14.0; IPHONEOS_DEPLOYMENT_TARGET = 17.0; }}; name = {config};')
    debug = 'SWIFT_OPTIMIZATION_LEVEL = "-Onone"; SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;' if config == "Debug" else 'SWIFT_OPTIMIZATION_LEVEL = "-O";'
    debug += ' ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;'
    obj("target-" + config, f'isa = XCBuildConfiguration; buildSettings = {{ CODE_SIGN_STYLE = Automatic; GENERATE_INFOPLIST_FILE = NO; INFOPLIST_FILE = Info.plist; PRODUCT_BUNDLE_IDENTIFIER = local.margin.reader; PRODUCT_NAME = Margin; SDKROOT = auto; SUPPORTED_PLATFORMS = "iphoneos iphonesimulator macosx"; TARGETED_DEVICE_FAMILY = "1,2"; ENABLE_HARDENED_RUNTIME = YES; SWIFT_EMIT_LOC_STRINGS = YES; {debug} }}; name = {config};')
for kind in ("project", "target"):
    obj(kind + "-config", f'isa = XCConfigurationList; buildConfigurations = ({ref(kind+"-Debug")}, {ref(kind+"-Release")}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
project = root / "Margin.xcodeproj"
project.mkdir(exist_ok=True)
(project / "project.pbxproj").write_text('// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n' + '\n'.join(objects) + f'\n\t}};\n\trootObject = {ref("project")};\n}}\n')
scheme_dir = project / "xcshareddata/xcschemes"
scheme_dir.mkdir(parents=True, exist_ok=True)
buildable = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ref("target")}" BuildableName="Margin.app" BlueprintName="Margin" ReferencedContainer="container:Margin.xcodeproj"/>'
(scheme_dir / "Margin.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{buildable}</BuildActionEntry></BuildActionEntries></BuildAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildable}</BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildable}</BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/>
 <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print(f"Generated {project.relative_to(root.parent)}")
