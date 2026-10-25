<?php

/*
 * Manifest <-> facade <-> native consistency, and the generic (app-free) setup.
 */

it('has complete marketplace metadata', function () {
    $m = manifest();

    expect($m)->toHaveKeys(['name', 'version', 'description', 'namespace', 'keywords', 'category', 'license', 'author', 'homepage', 'repository', 'platforms', 'bridge_functions', 'events', 'android', 'ios'])
        ->and($m['name'])->toBe('protendai/nativephp-lan')
        ->and($m['version'])->toBe('1.0.0')
        ->and($m['license'])->toBe('MIT')
        ->and($m['namespace'])->toBe('Lan')
        ->and($m['platforms'])->toBe(['android', 'ios'])
        ->and($m['homepage'])->toBe('https://github.com/protendai/nativephp-lan')
        ->and($m['author']['name'])->toBe('Tendai Karuma');
});

it('matches composer.json', function () {
    $composer = json_decode(file_get_contents(pluginPath('composer.json')), true);

    expect($composer['name'])->toBe(manifest()['name'])
        ->and($composer['license'])->toBe('MIT')
        ->and($composer['keywords'])->toContain('nativephp-plugin')
        ->and($composer['require'])->toHaveKey('nativephp/mobile')
        ->and($composer['require']['nativephp/mobile'])->toBe('^4.0')
        ->and($composer['extra']['laravel']['providers'])->toBe(['Protendai\\Lan\\LanServiceProvider'])
        ->and($composer['scripts']['test'])->toBe('pest');
});

it('declares the genuine minimum platform versions', function () {
    // Android: MediaStore.Downloads, ContentResolver.loadThumbnail, ThumbnailUtils(File, Size) are API 29.
    // iOS: UIImage.preparingThumbnail is iOS 15; FileHandle.write(contentsOf:) 13.4.
    expect(manifest()['android']['min_version'])->toBe(29)
        ->and(manifest()['ios']['min_version'])->toBe('15.0');
});

it('forces no app-wide Info.plist settings and names no app', function () {
    $plist = manifest()['ios']['info_plist'];

    expect(array_keys($plist))->toBe(['NSLocalNetworkUsageDescription'])
        ->and($plist['NSLocalNetworkUsageDescription'])->not->toBeEmpty();

    $everything = file_get_contents(pluginPath('nativephp.json')).kotlinSources().swiftSources()
        .implode('', array_map('file_get_contents', glob(pluginPath('src/{,*/}*.php'), GLOB_BRACE)))
        .file_get_contents(pluginPath('config/lan.php'))
        .file_get_contents(pluginPath('resources/js/index.js'));

    expect(strtolower($everything))->not->toContain('tumira')
        ->not->toContain('tuma')
        ->not->toContain('53480')
        ->not->toContain('224.0.0.167');
});

it('maps every bridge function to a Kotlin class, a Swift class and a facade call', function () {
    $kotlin = kotlinSources();
    $swift = swiftSources();
    $facade = file_get_contents(pluginPath('src/Lan.php'));

    foreach (manifest()['bridge_functions'] as $function) {
        [$namespace, $short] = explode('.', $function['name']);

        expect($namespace)->toBe('Lan')
            ->and($function['android'])->toBe("com.protendai.lan.LanFunctions.{$short}")
            ->and($function['ios'])->toBe("LanFunctions.{$short}")
            ->and($function['description'] ?? '')->not->toBeEmpty()
            ->and($kotlin)->toContain("class {$short}(private val activity: FragmentActivity) : BridgeFunction")
            ->and($swift)->toContain("class {$short}: BridgeFunction")
            ->and($facade)->toContain("'{$function['name']}'");
    }
});

it('keeps app-specific helpers out of the plugin', function () {
    $names = array_column(manifest()['bridge_functions'], 'name');

    expect($names)->not->toContain('Lan.SetAppearance')
        ->not->toContain('Lan.WakeQueue')
        ->and(kotlinSources())->not->toContain('UiModeManager')
        ->not->toContain('php-queue-worker')
        ->and(swiftSources())->not->toContain('overrideUserInterfaceStyle')
        ->and(manifest())->not->toHaveKey('hooks');
});

it('declares every Kotlin package as com.protendai.lan', function () {
    foreach (glob(pluginPath('resources/android/src/*.kt')) as $file) {
        expect(file_get_contents($file))->toStartWith('package com.protendai.lan');
    }
});

it('only dispatches declared events, from the plugin namespace', function () {
    $declared = array_map(fn (string $class) => class_basename($class), manifest()['events']);

    preg_match_all('/dispatch\(\s*"(\w+)"/', kotlinSources().swiftSources(), $matches);
    $dispatched = array_unique($matches[1]);
    $dispatched = array_merge($dispatched, ['UploadProgress', 'UploadComplete', 'PeerFound']); // via emit* helpers

    foreach (array_unique($dispatched) as $event) {
        expect($declared)->toContain($event);
    }

    expect(kotlinSources())->toContain('"Protendai\\\\Lan\\\\Events\\\\"')
        ->and(swiftSources())->toContain('"Protendai\\\\Lan\\\\Events\\\\"');
});

it('declares only events that exist', function () {
    foreach (manifest()['events'] as $event) {
        expect(class_exists($event))->toBeTrue("{$event} is missing");
    }

    expect(manifest()['events'])->not->toContain('Protendai\\Lan\\Events\\PeerLost');
});

it('ships config defaults identical to the facade defaults', function () {
    $config = require pluginPath('config/lan.php');

    expect($config)->toBe(\Protendai\Lan\Lan::DEFAULTS);
});
