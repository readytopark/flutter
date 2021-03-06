// Copyright 2017 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:meta/meta.dart';
import 'package:mustache/mustache.dart' as mustache;
import 'package:yaml/yaml.dart';

import 'base/file_system.dart';
import 'dart/package_map.dart';
import 'flutter_manifest.dart';
import 'globals.dart';
import 'ios/cocoapods.dart';

void _renderTemplateToFile(String template, dynamic context, String filePath) {
  final String renderedTemplate =
     new mustache.Template(template).renderString(context);
  final File file = fs.file(filePath);
  file.createSync(recursive: true);
  file.writeAsStringSync(renderedTemplate);
}

class Plugin {
  final String name;
  final String path;
  final String androidPackage;
  final String iosPrefix;
  final String pluginClass;

  Plugin({
    this.name,
    this.path,
    this.androidPackage,
    this.iosPrefix,
    this.pluginClass,
  });

  factory Plugin.fromYaml(String name, String path, dynamic pluginYaml) {
    String androidPackage;
    String iosPrefix;
    String pluginClass;
    if (pluginYaml != null) {
      androidPackage = pluginYaml['androidPackage'];
      iosPrefix = pluginYaml['iosPrefix'] ?? '';
      pluginClass = pluginYaml['pluginClass'];
    }
    return new Plugin(
      name: name,
      path: path,
      androidPackage: androidPackage,
      iosPrefix: iosPrefix,
      pluginClass: pluginClass,
    );
  }
}

Plugin _pluginFromPubspec(String name, Uri packageRoot) {
  final String pubspecPath = fs.path.fromUri(packageRoot.resolve('pubspec.yaml'));
  if (!fs.isFileSync(pubspecPath))
    return null;
  final dynamic pubspec = loadYaml(fs.file(pubspecPath).readAsStringSync());
  if (pubspec == null)
    return null;
  final dynamic flutterConfig = pubspec['flutter'];
  if (flutterConfig == null || !flutterConfig.containsKey('plugin'))
    return null;
  final String packageRootPath = fs.path.fromUri(packageRoot);
  printTrace('Found plugin $name at $packageRootPath');
  return new Plugin.fromYaml(name, packageRootPath, flutterConfig['plugin']);
}

List<Plugin> findPlugins(String directory) {
  final List<Plugin> plugins = <Plugin>[];
  Map<String, Uri> packages;
  try {
    final String packagesFile = fs.path.join(directory, PackageMap.globalPackagesPath);
    packages = new PackageMap(packagesFile).map;
  } on FormatException catch (e) {
    printTrace('Invalid .packages file: $e');
    return plugins;
  }
  packages.forEach((String name, Uri uri) {
    final Uri packageRoot = uri.resolve('..');
    final Plugin plugin = _pluginFromPubspec(name, packageRoot);
    if (plugin != null)
      plugins.add(plugin);
  });
  return plugins;
}

/// Returns true if .flutter-plugins has changed, otherwise returns false.
bool _writeFlutterPluginsList(String directory, List<Plugin> plugins) {
  final File pluginsFile = fs.file(fs.path.join(directory, '.flutter-plugins'));
  final String oldContents = _readFlutterPluginsList(directory);
  final String pluginManifest =
      plugins.map((Plugin p) => '${p.name}=${escapePath(p.path)}').join('\n');
  if (pluginManifest.isNotEmpty) {
    pluginsFile.writeAsStringSync('$pluginManifest\n', flush: true);
  } else {
    if (pluginsFile.existsSync())
      pluginsFile.deleteSync();
  }
  final String newContents = _readFlutterPluginsList(directory);
  return oldContents != newContents;
}

/// Returns the contents of the `.flutter-plugins` file in [directory], or
/// null if that file does not exist.
String _readFlutterPluginsList(String directory) {
  final File pluginsFile = fs.file(fs.path.join(directory, '.flutter-plugins'));
  return pluginsFile.existsSync() ? pluginsFile.readAsStringSync() : null;
}

const String _androidPluginRegistryTemplate = '''package io.flutter.plugins;

import io.flutter.plugin.common.PluginRegistry;
{{#plugins}}
import {{package}}.{{class}};
{{/plugins}}

/**
 * Generated file. Do not edit.
 */
public final class GeneratedPluginRegistrant {
  public static void registerWith(PluginRegistry registry) {
    if (alreadyRegisteredWith(registry)) {
      return;
    }
{{#plugins}}
    {{class}}.registerWith(registry.registrarFor("{{package}}.{{class}}"));
{{/plugins}}
  }

  private static boolean alreadyRegisteredWith(PluginRegistry registry) {
    final String key = GeneratedPluginRegistrant.class.getCanonicalName();
    if (registry.hasPlugin(key)) {
      return true;
    }
    registry.registrarFor(key);
    return false;
  }
}
''';

void _writeAndroidPluginRegistrant(String directory, List<Plugin> plugins) {
  final List<Map<String, dynamic>> androidPlugins = plugins
      .where((Plugin p) => p.androidPackage != null && p.pluginClass != null)
      .map((Plugin p) => <String, dynamic>{
          'name': p.name,
          'package': p.androidPackage,
          'class': p.pluginClass,
      })
      .toList();
  final Map<String, dynamic> context = <String, dynamic>{
    'plugins': androidPlugins,
  };

  final String javaSourcePath = fs.path.join(directory, 'src', 'main', 'java');
  final String registryPath = fs.path.join(javaSourcePath, 'io', 'flutter', 'plugins', 'GeneratedPluginRegistrant.java');
  _renderTemplateToFile(_androidPluginRegistryTemplate, context, registryPath);
}

const String _iosPluginRegistryHeaderTemplate = '''//
//  Generated file. Do not edit.
//

#ifndef GeneratedPluginRegistrant_h
#define GeneratedPluginRegistrant_h

#import <Flutter/Flutter.h>

@interface GeneratedPluginRegistrant : NSObject
+ (void)registerWithRegistry:(NSObject<FlutterPluginRegistry>*)registry;
@end

#endif /* GeneratedPluginRegistrant_h */
''';

const String _iosPluginRegistryImplementationTemplate = '''//
//  Generated file. Do not edit.
//

#import "GeneratedPluginRegistrant.h"
{{#plugins}}
#import <{{name}}/{{class}}.h>
{{/plugins}}

@implementation GeneratedPluginRegistrant

+ (void)registerWithRegistry:(NSObject<FlutterPluginRegistry>*)registry {
{{#plugins}}
  [{{prefix}}{{class}} registerWithRegistrar:[registry registrarForPlugin:@"{{prefix}}{{class}}"]];
{{/plugins}}
}

@end
''';

const String _iosPluginRegistrantPodspecTemplate = '''
#
# Generated file, do not edit.
#

Pod::Spec.new do |s|
  s.name             = 'FlutterPluginRegistrant'
  s.version          = '0.0.1'
  s.summary          = 'Registers plugins with your flutter app'
  s.description      = <<-DESC
Depends on all your plugins, and provides a function to register them.
                       DESC
  s.homepage         = 'https://flutter.io'
  s.license          = { :type => 'BSD' }
  s.author           = { 'Flutter Dev Team' => 'flutter-dev@googlegroups.com' }
  s.ios.deployment_target = '7.0'
  s.source_files =  "Classes", "Classes/**/*.{h,m}"
  s.source           = { :path => '.' }
  s.public_header_files = './Classes/**/*.h'
  {{#plugins}}
  s.dependency '{{name}}'
  {{/plugins}}
end
''';

void _writeIOSPluginRegistrant(String directory, FlutterManifest manifest, List<Plugin> plugins) {
  final List<Map<String, dynamic>> iosPlugins = plugins
      .where((Plugin p) => p.pluginClass != null)
      .map((Plugin p) => <String, dynamic>{
    'name': p.name,
    'prefix': p.iosPrefix,
    'class': p.pluginClass,
  }).
  toList();
  final Map<String, dynamic> context = <String, dynamic>{
    'plugins': iosPlugins,
  };

  if (manifest.isModule) {
    // In a module create the GeneratedPluginRegistrant as a pod to be included
    // from a hosting app.
    final String registryDirectory = fs.path.join(directory, 'FlutterPluginRegistrant');
    final String registryClassesDirectory = fs.path.join(registryDirectory, 'Classes');
    _renderTemplateToFile(
      _iosPluginRegistrantPodspecTemplate,
      context,
      fs.path.join(registryDirectory, 'FlutterPluginRegistrant.podspec'),
    );
    _renderTemplateToFile(
      _iosPluginRegistryHeaderTemplate,
      context,
      fs.path.join(registryClassesDirectory, 'GeneratedPluginRegistrant.h'),
    );
    _renderTemplateToFile(
      _iosPluginRegistryImplementationTemplate,
      context,
      fs.path.join(registryClassesDirectory, 'GeneratedPluginRegistrant.m'),
    );
  } else {
    // For a non-module create the GeneratedPluginRegistrant as source files
    // directly in the ios project.
    final String runnerDirectory = fs.path.join(directory, 'Runner');
    _renderTemplateToFile(
      _iosPluginRegistryHeaderTemplate,
      context,
      fs.path.join(runnerDirectory, 'GeneratedPluginRegistrant.h'),
    );
    _renderTemplateToFile(
      _iosPluginRegistryImplementationTemplate,
      context,
      fs.path.join(runnerDirectory, 'GeneratedPluginRegistrant.m'),
    );
  }
}

class InjectPluginsResult{
  InjectPluginsResult({
    @required this.hasPlugin,
    @required this.hasChanged,
  });
  /// True if any flutter plugin exists, otherwise false.
  final bool hasPlugin;
  /// True if plugins have changed since last build.
  final bool hasChanged;
}

/// Injects plugins found in `pubspec.yaml` into the platform-specific projects.
void injectPlugins({@required String projectPath, @required FlutterManifest manifest}) {
  final List<Plugin> plugins = findPlugins(projectPath);
  final bool changed = _writeFlutterPluginsList(projectPath, plugins);
  if (manifest.isModule) {
    _writeAndroidPluginRegistrant(fs.path.join(projectPath, '.android', 'Flutter'), plugins);
  } else if (fs.isDirectorySync(fs.path.join(projectPath, 'android', 'app'))) {
    _writeAndroidPluginRegistrant(fs.path.join(projectPath, 'android', 'app'), plugins);
  }
  if (manifest.isModule) {
    _writeIOSPluginRegistrant(fs.path.join(projectPath, '.ios'), manifest, plugins);
  } else if (fs.isDirectorySync(fs.path.join(projectPath, 'ios'))) {
    _writeIOSPluginRegistrant(fs.path.join(projectPath, 'ios'), manifest, plugins);
    final CocoaPods cocoaPods = new CocoaPods();
    if (plugins.isNotEmpty)
      cocoaPods.setupPodfile(projectPath, manifest);
    if (changed)
      cocoaPods.invalidatePodInstallOutput(projectPath);
  }
}

/// Returns whether the Flutter project at the specified [directory]
/// has any plugin dependencies.
bool hasPlugins({String directory}) {
  directory ??= fs.currentDirectory.path;
  return _readFlutterPluginsList(directory) != null;
}
