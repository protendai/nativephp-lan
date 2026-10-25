<?php

it('exports a JavaScript function for every bridge function', function () {
    $js = file_get_contents(pluginPath('resources/js/index.js'));
    $dts = file_get_contents(pluginPath('resources/js/index.d.ts'));

    foreach (manifest()['bridge_functions'] as $function) {
        expect($js)->toContain("'{$function['name']}'");
    }

    preg_match_all('/^export (?:async )?function (\w+)/m', $js, $functions);
    foreach ($functions[1] as $name) {
        expect($dts)->toContain("export function {$name}(");
    }
});

it('exports every event name in JavaScript', function () {
    $js = file_get_contents(pluginPath('resources/js/index.js'));

    foreach (manifest()['events'] as $event) {
        $short = class_basename($event);
        expect($js)->toContain("{$short}: '".str_replace('\\', '\\\\', $event)."'");
    }
});

it('ships the same defaults in JavaScript as in config/lan.php', function () {
    $js = file_get_contents(pluginPath('resources/js/index.js'));
    $config = lan()->config();

    foreach ($config as $key => $value) {
        $literal = is_string($value) ? "'{$value}'" : (string) $value;
        expect($js)->toContain("{$key}: {$literal},");
    }
});

it('has an npm package description', function () {
    $package = json_decode(file_get_contents(pluginPath('resources/js/package.json')), true);

    expect($package['name'])->toBe('@protendai/nativephp-lan')
        ->and($package['private'])->toBeFalse()
        ->and($package['license'])->toBe('MIT');
});
