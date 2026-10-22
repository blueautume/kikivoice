#!/usr/bin/env python3
"""Regenerate the small, dependency-free Xcode project after adding Swift sources."""
from pathlib import Path
import hashlib
import json

root = Path(__file__).resolve().parent
objects = {}

def ident(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()

def ref(name):
    return Ref(ident(name))

class Ref(str):
    pass

def add(key, **values):
    objects[ident(key)] = values
    return ref(key)

def serialize(value):
    if isinstance(value, Ref): return str(value)
    if isinstance(value, dict): return "{ " + " ".join(f"{key} = {serialize(val)};" for key, val in value.items()) + " }"
    if isinstance(value, list): return "(" + ", ".join(serialize(item) for item in value) + ")"
    return json.dumps(str(value), ensure_ascii=False)

app_sources = sorted((root / "App").glob("*.swift"))
test_sources = sorted((root / "Tests").glob("*.swift"))
app_files, app_builds, test_files, test_builds = [], [], [], []
for group, paths, files, builds in [("App", app_sources, app_files, app_builds), ("Tests", test_sources, test_files, test_builds)]:
    for path in paths:
        source = add(f"file:{group}/{path.name}", isa="PBXFileReference", lastKnownFileType="sourcecode.swift", path=path.name, sourceTree="<group>")
        files.append(source)
        builds.append(add(f"build:{group}/{path.name}", isa="PBXBuildFile", fileRef=source))

app_resources = []
for filename, kind in [("Assets.xcassets", "folder.assetcatalog"), ("PrivacyInfo.xcprivacy", "text.xml")]:
    source = add(f"file:App/{filename}", isa="PBXFileReference", lastKnownFileType=kind, path=filename, sourceTree="<group>")
    app_files.append(source)
    app_resources.append(add(f"build:App/{filename}", isa="PBXBuildFile", fileRef=source))
app_files.append(add("file:App/KikiVoiceOps.entitlements", isa="PBXFileReference", lastKnownFileType="text.plist.entitlements", path="KikiVoiceOps.entitlements", sourceTree="<group>"))
app_files.append(add("file:App/Info.plist", isa="PBXFileReference", lastKnownFileType="text.plist.xml", path="Info.plist", sourceTree="<group>"))
fixture_builds = []
for path in sorted((root / "Tests").glob("*.json")):
    fixture = add(f"file:Tests/{path.name}", isa="PBXFileReference", lastKnownFileType="text.json", path=path.name, sourceTree="<group>")
    test_files.append(fixture)
    fixture_builds.append(add(f"build:Tests/{path.name}", isa="PBXBuildFile", fileRef=fixture))
app_product = add("product:app", isa="PBXFileReference", explicitFileType="wrapper.application", path="KikiVoiceOps.app", sourceTree="BUILT_PRODUCTS_DIR")
test_product = add("product:tests", isa="PBXFileReference", explicitFileType="wrapper.cfbundle", path="KikiVoiceOpsTests.xctest", sourceTree="BUILT_PRODUCTS_DIR")
app_group = add("group:App", isa="PBXGroup", children=app_files, path="App", sourceTree="<group>")
test_group = add("group:Tests", isa="PBXGroup", children=test_files, path="Tests", sourceTree="<group>")
products = add("group:Products", isa="PBXGroup", children=[app_product, test_product], name="Products", sourceTree="<group>")
main_group = add("group:root", isa="PBXGroup", children=[app_group, test_group, products], sourceTree="<group>")

def phases(name, sources, resources):
    return [add(f"phase:{name}:sources", isa="PBXSourcesBuildPhase", buildActionMask=2147483647, files=sources, runOnlyForDeploymentPostprocessing=0),
            add(f"phase:{name}:frameworks", isa="PBXFrameworksBuildPhase", buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0),
            add(f"phase:{name}:resources", isa="PBXResourcesBuildPhase", buildActionMask=2147483647, files=resources, runOnlyForDeploymentPostprocessing=0)]

common = {"CLANG_ENABLE_MODULES":"YES", "CLANG_ENABLE_OBJC_ARC":"YES", "IPHONEOS_DEPLOYMENT_TARGET":"17.0", "SDKROOT":"iphoneos", "SWIFT_VERSION":"5.0", "TARGETED_DEVICE_FAMILY":"1,2", "DEVELOPMENT_TEAM":"A82X46N3WS", "CODE_SIGN_STYLE":"Automatic"}
app_settings = {"CODE_SIGN_ENTITLEMENTS":"App/KikiVoiceOps.entitlements","PRODUCT_BUNDLE_IDENTIFIER":"com.kikitalk.voiceops", "PRODUCT_NAME":"$(TARGET_NAME)", "INFOPLIST_FILE":"App/Info.plist", "ASSETCATALOG_COMPILER_APPICON_NAME":"AppIcon", "CURRENT_PROJECT_VERSION":"1", "MARKETING_VERSION":"1.0", "LD_RUNPATH_SEARCH_PATHS":["$(inherited)", "@executable_path/Frameworks"], "SUPPORTED_PLATFORMS":"iphoneos iphonesimulator", "SUPPORTS_MACCATALYST":"NO", "SWIFT_EMIT_LOC_STRINGS":"YES"}
test_settings = {"PRODUCT_BUNDLE_IDENTIFIER":"com.kikitalk.voiceops.tests", "PRODUCT_NAME":"$(TARGET_NAME)", "GENERATE_INFOPLIST_FILE":"YES", "BUNDLE_LOADER":"$(TEST_HOST)", "TEST_HOST":"$(BUILT_PRODUCTS_DIR)/KikiVoiceOps.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/KikiVoiceOps", "LD_RUNPATH_SEARCH_PATHS":["$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks"]}

def configuration_list(name, extra):
    refs = []
    for config in ["Debug", "Release"]:
        settings = dict(extra)
        if name == "Project":
            settings.update({"SWIFT_OPTIMIZATION_LEVEL":"-Onone" if config == "Debug" else "-O", "DEBUG_INFORMATION_FORMAT":"dwarf" if config == "Debug" else "dwarf-with-dsym", "ENABLE_TESTABILITY":"YES" if config == "Debug" else "NO"})
        refs.append(add(f"config:{name}:{config}", isa="XCBuildConfiguration", name=config, buildSettings=settings))
    return add(f"configs:{name}", isa="XCConfigurationList", buildConfigurations=refs, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")

project_configs = configuration_list("Project", common)
app_configs = configuration_list("App", app_settings)
test_configs = configuration_list("Tests", test_settings)
app_phases = phases("app", app_builds, app_resources)
test_phases = phases("test", test_builds, fixture_builds)
proxy = add("proxy:app", isa="PBXContainerItemProxy", containerPortal=ref("project"), proxyType=1, remoteGlobalIDString=ref("target:app"), remoteInfo="KikiVoiceOps")
dependency = add("dependency:app", isa="PBXTargetDependency", target=ref("target:app"), targetProxy=proxy)
app_target = add("target:app", isa="PBXNativeTarget", buildConfigurationList=app_configs, buildPhases=app_phases, buildRules=[], dependencies=[], name="KikiVoiceOps", productName="KikiVoiceOps", productReference=app_product, productType="com.apple.product-type.application")
test_target = add("target:test", isa="PBXNativeTarget", buildConfigurationList=test_configs, buildPhases=test_phases, buildRules=[], dependencies=[dependency], name="KikiVoiceOpsTests", productName="KikiVoiceOpsTests", productReference=test_product, productType="com.apple.product-type.bundle.unit-test")
add("project", isa="PBXProject", attributes={"BuildIndependentTargetsInParallel":"YES", "LastUpgradeCheck":"2650", "TargetAttributes":{str(app_target):{"CreatedOnToolsVersion":"26.5","SystemCapabilities":{"com.apple.AssociatedDomains":{"enabled":1}}},str(test_target):{"CreatedOnToolsVersion":"26.5","TestTargetID":app_target}}}, buildConfigurationList=project_configs, compatibilityVersion="Xcode 14.0", developmentRegion="zh_CN", hasScannedForEncodings=0, knownRegions=["zh_CN", "en", "Base"], mainGroup=main_group, productRefGroup=products, projectDirPath="", projectRoot="", targets=[app_target, test_target])
body = "// !$*UTF8*$!\n{\narchiveVersion = 1;\nclasses = {};\nobjectVersion = 56;\nobjects = {\n"
body += "\n".join(f"{key} = {serialize(value)};" for key, value in objects.items())
body += f"\n}};\nrootObject = {ref('project')};\n}}\n"
(root / "KikiVoiceOps.xcodeproj/project.pbxproj").write_text(body)
scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2650" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
    <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}" BuildableName="KikiVoiceOps.app" BlueprintName="KikiVoiceOps" ReferencedContainer="container:KikiVoiceOps.xcodeproj"/></BuildActionEntry>
  </BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{test_target}" BuildableName="KikiVoiceOpsTests.xctest" BlueprintName="KikiVoiceOpsTests" ReferencedContainer="container:KikiVoiceOps.xcodeproj"/></TestableReference></Testables></TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}" BuildableName="KikiVoiceOps.app" BlueprintName="KikiVoiceOps" ReferencedContainer="container:KikiVoiceOps.xcodeproj"/></BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}" BuildableName="KikiVoiceOps.app" BlueprintName="KikiVoiceOps" ReferencedContainer="container:KikiVoiceOps.xcodeproj"/></BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
(root / "KikiVoiceOps.xcodeproj/xcshareddata/xcschemes/KikiVoiceOps.xcscheme").write_text(scheme)
