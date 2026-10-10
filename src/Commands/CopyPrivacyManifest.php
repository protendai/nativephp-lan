<?php

namespace Tuma\Lan\Commands;

use Native\Mobile\Plugins\Commands\NativePluginHookCommand;

/**
 * post_compile hook for the iOS build: put Tumira's App Store privacy
 * manifest (PrivacyInfo.xcprivacy) into the bundle (NativePHP only copies a
 * plugin's .swift files) and make Info.plist booleans real booleans.
 */
class CopyPrivacyManifest extends NativePluginHookCommand
{
    protected $signature = 'tuma:lan:privacy-manifest';

    protected $description = "Copy Tumira's PrivacyInfo.xcprivacy into the iOS bundle";

    public function handle(): int
    {
        if (! $this->isIos()) {
            return self::SUCCESS;
        }

        if (! $this->copyToIosBundle('ios-bundle/PrivacyInfo.xcprivacy', 'PrivacyInfo.xcprivacy')) {
            $this->warn('Could not copy PrivacyInfo.xcprivacy into the iOS bundle.');
        }

        foreach (['NativePHP/Info.plist', 'NativePHP-simulator-Info.plist'] as $plist) {
            $this->fixBooleans($this->buildPath().'/'.$plist);
        }

        return self::SUCCESS;
    }

    /**
     * NativePHP writes every Info.plist value as <string> (false becomes "",
     * true becomes "1"); App Store validation wants real booleans here.
     */
    private const BOOLEANS = [
        'ITSAppUsesNonExemptEncryption' => false,
        'UIFileSharingEnabled' => true,
        'LSSupportsOpeningDocumentsInPlace' => true,
    ];

    private function fixBooleans(string $path): void
    {
        if (! is_file($path)) {
            return;
        }

        $xml = (string) file_get_contents($path);
        $fixed = $xml;

        foreach (self::BOOLEANS as $key => $value) {
            $fixed = (string) preg_replace(
                '#(<key>'.preg_quote($key, '#').'</key>\s*)<string>[^<]*</string>#',
                '$1'.($value ? '<true/>' : '<false/>'),
                $fixed,
            );
        }

        if ($fixed !== $xml) {
            file_put_contents($path, $fixed);
        }
    }
}
